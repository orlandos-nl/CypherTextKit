import BSON
import Crypto
import Foundation
import NIO

@available(macOS 10.15, iOS 13, *)
final class JobQueue {
    weak private(set) var messenger: CypherMessenger?
    private let database: CypherMessengerStore
    private let databaseEncryptionKey: SymmetricKey
    @JobQueueActor public private(set) var runningJobs = false
    @JobQueueActor public private(set) var hasOutstandingTasks = true
    @JobQueueActor private var pausing: EventLoopPromise<Void>?
    @JobQueueActor private var jobs: [_DecryptedModel<JobModel>] {
        didSet {
            markAsDone()
        }
    }
    private let eventLoop: EventLoop
    private static var taskDecoders = [TaskKey: TaskDecoder]()

    init(messenger: CypherMessenger, database: CypherMessengerStore, databaseEncryptionKey: SymmetricKey) {
        self.messenger = messenger
        self.eventLoop = messenger.eventLoop
        self.database = database
        self.databaseEncryptionKey = databaseEncryptionKey
        self.jobs = []
    }
    
    @JobQueueActor
    func loadJobs() async throws {
        self.jobs = try await database.readJobs().map { job -> (Date, _DecryptedModel<JobModel>) in
            let job = try messenger!._cachelessDecrypt(job)
            return (job.scheduledAt, job)
        }.sorted { lhs, rhs in
            lhs.0 < rhs.0
        }.map(\.1)
    }
    
    static func registerTask<T: StoredTask>(_ task: T.Type, forKey key: TaskKey) {
        taskDecoders[key] = { document in
            try BSONDecoder().decode(task, from: document)
        }
    }
    
    @JobQueueActor
    func cancelJob(_ job: _DecryptedModel<JobModel>) async throws {
        // TODO: What if the job is cancelled while executing and succeeding?
        try await dequeueJob(job)
    }
    
    @JobQueueActor
    func dequeueJob(_ job: _DecryptedModel<JobModel>) async throws {
        try await database.removeJob(job.encrypted)
        for i in 0..<self.jobs.count {
            if self.jobs[i].id == job.id {
                self.jobs.remove(at: i)
                return
            }
        }
    }
    
    @JobQueueActor
    public func queueTask<T: StoredTask>(_ task: T) async throws {
        guard let messenger = self.messenger else {
            throw CypherSDKError.appLocked
        }
        
        let job = try JobModel(
            props: .init(task: task),
            encryptionKey: databaseEncryptionKey
        )
        
        let queuedJob = try messenger._cachelessDecrypt(job)
        self.jobs.append(queuedJob)
        self.hasOutstandingTasks = true
        try await database.createJob(job)
        if !self.runningJobs {
            self.startRunningTasks()
        }
    }
    
    @JobQueueActor
    public func queueTasks<T: StoredTask>(_ tasks: [T]) async throws {
        if tasks.isEmpty {
            return
        }
        
        guard let messenger = self.messenger else {
            throw CypherSDKError.appLocked
        }
        
        let jobs = try tasks.map { task in
            try JobModel(
                props: .init(task: task),
                encryptionKey: databaseEncryptionKey
            )
        }
        
        var queuedJobs = [_DecryptedModel<JobModel>]()
        
        for job in jobs {
            queuedJobs.append(try messenger._cachelessDecrypt(job))
        }
        
        do {
            for job in jobs {
                try await database.createJob(job)
            }
        } catch {
            debugLog("Failed to queue all jobs of type \(T.self)")
            
            for job in jobs {
                try? await database.removeJob(job)
            }
            
            throw error
        }
        
        self.jobs.append(contentsOf: queuedJobs)
        self.hasOutstandingTasks = true
        
        if !self.runningJobs {
            self.startRunningTasks()
        }
    }
    
    @JobQueueActor fileprivate var isDoneNotifications = [EventLoopPromise<Void>]()
    
    @JobQueueActor
    func awaitDoneProcessing(untilEmpty: Bool) async throws -> SynchronisationResult {
        if hasOutstandingTasks, !jobs.isEmpty, let messenger = messenger {
            if !untilEmpty, nextJob() == nil {
                return .skipped
            }
            
            let promise = messenger.eventLoop.makePromise(of: Void.self)
            self.isDoneNotifications.append(promise)
            startRunningTasks()
            try await promise.futureResult.get()
            return .synchronised
        } else {
            return .skipped
        }
    }
    
    @JobQueueActor
    func markAsDone() {
        for notification in isDoneNotifications {
            notification.succeed(())
        }
        
        isDoneNotifications = []
    }
    
    @JobQueueActor
    func startRunningTasks() {
        debugLog("Starting job queue")
        
        if let messenger = messenger, !messenger.isOnline, !messenger.canBroadcastInMesh {
            debugLog("App is offline, aborting")
            return
        }

        if runningJobs {
            debugLog("Job queue already running")
            return
        }

        if let pausing = pausing {
            debugLog("Pausing job queue")
            pausing.succeed(())
            return
        }

        debugLog("Job queue started")
        runningJobs = true

        @JobQueueActor @Sendable func next() async throws {
            guard let messenger = self.messenger else {
                return
            }
            
            debugLog("Looking for next task")
            if self.jobs.isEmpty {
                debugLog("No more tasks")
                self.runningJobs = false
                self.hasOutstandingTasks = false
                self.markAsDone()
                return
            }

            let result: TaskResult
            
            do {
                result = try await runNextJob()
            } catch {
                debugLog("Task error", error)
                result = .failed(haltExecution: true)
            }
            
            if let pausing = self.pausing {
                debugLog("Job finished, pausing started. Stopping further processing")
                self.runningJobs = false
                pausing.succeed(())
                return
            } else {
                switch result {
                case .success, .delayed, .failed(haltExecution: false):
                    return try await next()
                case .waitingForDelays:
                    self.runningJobs = false
                    self.markAsDone()
                case .failed(haltExecution: true):
                    for job in self.jobs {
                        let task: StoredTask
                        
                        let taskKey = TaskKey(rawValue: job.taskKey)
                        if let decoder = Self.taskDecoders[taskKey] {
                            task = try decoder(job.task)
                        } else {
                            task = try BSONDecoder().decode(CypherTask.self, from: job.task)
                        }
                        
                        try await task.onDelayed(on: messenger)
                    }

                    debugLog("Task failed or none found, stopping processing")
                    self.runningJobs = false
                }
            }
        }

        Task.detached { @JobQueueActor in
            // Lock in the current queue
            if self.jobs.isEmpty {
                debugLog("No jobs to run")
                self.hasOutstandingTasks = false
                self.runningJobs = false
                self.markAsDone()
            } else {
                var hasUsefulTasks = false
                
                findUsefulTasks: for job in self.jobs {
                    if let delayedUntil = job.delayedUntil, delayedUntil >= Date() {
                        if !job.props.isBackgroundTask {
                            break findUsefulTasks
                        }
                        
                        continue findUsefulTasks
                    }
                    
                    hasUsefulTasks = true
                    break findUsefulTasks
                }
                
                guard hasUsefulTasks else {
                    debugLog("All jobs are delayed")
                    self.hasOutstandingTasks = false
                    self.runningJobs = false
                    return
                }
                
                do {
                    try await next()
                } catch {
                    debugLog("Job queue error", error)
                    self.runningJobs = false
                    self.pausing?.succeed(())
                }
            }
        }
    }
    
    @JobQueueActor
    public func resume() {
        pausing = nil
        startRunningTasks()
    }
    
    @JobQueueActor
    public func restart() async throws {
        try await pause()
        resume()
    }

    @JobQueueActor
    public func pause() async throws {
        let promise = eventLoop.makePromise(of: Void.self)
        pausing = promise
        if !runningJobs {
            promise.succeed(())
        }

        return try await promise.futureResult.get()
    }

    public enum TaskResult {
        case success, delayed, failed(haltExecution: Bool)
        case waitingForDelays
    }
    
    @JobQueueActor
    private func nextJob() -> _DecryptedModel<JobModel>? {
        debugLog("Available jobs", jobs.count)
        var index = 0
        let initialJob = jobs[0]
        
        findOtherJob: if (initialJob.props.isBackgroundTask && jobs.count > 1) || initialJob.delayedUntil != nil {
            if let delayedUntil = initialJob.delayedUntil, delayedUntil <= Date() {
                break findOtherJob
            }
            
            findBetterTask: for newIndex in 1..<jobs.count {
                let newJob = jobs[newIndex]
                if !newJob.props.isBackgroundTask {
                    if let delayedUntil = newJob.delayedUntil, delayedUntil > Date() {
                        continue findBetterTask
                    }
                    
                    index = newIndex
                    break findBetterTask
                }
            }
        }
        
        let job = jobs[index]
        
        if let delayedUntil = job.delayedUntil, delayedUntil > Date() {
            return nil
        } else {
            return job
        }
    }

    @JobQueueActor
    private func runNextJob() async throws -> TaskResult {
        guard let job = nextJob() else {
            return .waitingForDelays
        }

        debugLog("Running job", job.props)

        if let delayedUntil = job.delayedUntil, delayedUntil >= Date() {
            debugLog("Task was delayed into the future")
            return .delayed
        }
        
        let task: StoredTask
        
        do {
            let taskKey = TaskKey(rawValue: job.props.taskKey)
            if let decoder = Self.taskDecoders[taskKey] {
                task = try decoder(job.props.task)
            } else {
                task = try BSONDecoder().decode(CypherTask.self, from: job.task)
            }
        } catch {
            debugLog("Failed to decode job", job.id, ". Error:", error)
            try await self.dequeueJob(job)
            return .success
        }
        
        guard let messenger = self.messenger else {
            throw CypherSDKError.appLocked
        }
        
        if task.requiresConnectivity(on: messenger), messenger.isOnline, messenger.authenticated != .authenticated {
            debugLog("Job required connectivity, but app is offline")
            throw CypherSDKError.offline
        }

        do {
            try await task.execute(on: messenger)
            try await self.dequeueJob(job)
            return .success
        } catch {
            debugLog("Job error", error)

            switch task.retryMode.raw {
            case .retryAfter(let retryDelay, let maxAttempts):
                debugLog("Delaying task for \(retryDelay) seconds")
                try job.delayExecution(retryDelay: retryDelay)
                
                if let maxAttempts = maxAttempts, job.attempts >= maxAttempts {
                    try await self.cancelJob(job)
                    return .success
                }

                try await self.database.updateJob(job.encrypted)
                return .delayed
            case .always:
                return .delayed
            case .never:
                try await self.dequeueJob(job)
                return .failed(haltExecution: false)
            }
        }
    }
}
