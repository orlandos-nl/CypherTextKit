import BSON
import Crypto
import Foundation
import SwiftUI
import NIO

@available(macOS 12, iOS 15, *)
final class JobQueue: ObservableObject {
    public let eventLoop: EventLoop
    weak private(set) var messenger: CypherMessenger?
    private let database: CypherMessengerStore
    private let databaseEncryptionKey: SymmetricKey
    public private(set) var runningJobs = false
    public private(set) var hasOutstandingTasks = true
    private var pausing: EventLoopPromise<Void>?
    private var jobs: [DecryptedModel<JobModel>] {
        didSet {
            markAsDone()
        }
    }
    private static var taskDecoders = [TaskKey: TaskDecoder]()

    init(messenger: CypherMessenger, database: CypherMessengerStore, databaseEncryptionKey: SymmetricKey) async throws {
        self.eventLoop = messenger.eventLoop
        self.messenger = messenger
        self.database = database
        self.databaseEncryptionKey = databaseEncryptionKey
        self.jobs = try await database.readJobs().asyncMap { job -> (Date, DecryptedModel<JobModel>) in
            let job = try await messenger.decrypt(job)
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
    
    func cancelJob(_ job: DecryptedModel<JobModel>) async throws {
        // TODO: What if the job is cancelled while executing and succeeding?
        try await dequeueJob(job)
    }
    
    func dequeueJob(_ job: DecryptedModel<JobModel>) async throws {
        try await database.removeJob(job.encrypted)
        try await eventLoop.submit {
            for i in 0..<self.jobs.count {
                if self.jobs[i].id == job.id {
                    self.jobs.remove(at: i)
                    return
                }
            }
        }.get()
    }
    
    @MainActor public func queueTask<T: StoredTask>(_ task: T) async throws {
        guard let messenger = self.messenger else {
            throw CypherSDKError.appLocked
        }
        
        let job = try JobModel(
            props: .init(task: task),
            encryptionKey: databaseEncryptionKey
        )
        
        let queuedJob = try await messenger.decrypt(job)
        try await eventLoop.submit {
            self.jobs.append(queuedJob)
        }.get()
        self.hasOutstandingTasks = true
        try await database.createJob(job)
        if !self.runningJobs {
            self.startRunningTasks()
        }
    }
    
    fileprivate var isDoneNotifications = [EventLoopPromise<Void>]()
    func awaitDoneProcessing() async throws -> SynchronisationResult {
//        if runningJobs {
//            return .busy
//        } else
        if hasOutstandingTasks {
            let promise = eventLoop.makePromise(of: Void.self)
            self.isDoneNotifications.append(promise)
            startRunningTasks()
            try await promise.futureResult.get()
            return .synchronised
        } else {
            return .skipped
        }
    }
    
    func markAsDone() {
        if !hasOutstandingTasks && !isDoneNotifications.isEmpty {
            for notification in isDoneNotifications {
                notification.succeed(())
            }
            
            isDoneNotifications = []
        }
    }

    func startRunningTasks() {
        debugLog("Starting job queue")

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

        @MainActor func next() async throws {
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
                result = try await runNextJob(in: &self.jobs)
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
                case .failed(haltExecution: true):
                    let done = await self.jobs.asyncMap { job -> EventLoopFuture<Void> in
                        let task: StoredTask
                        
                        do {
                            let taskKey = TaskKey(rawValue: job.taskKey)
                            if let decoder = Self.taskDecoders[taskKey] {
                                task = try decoder(job.task)
                            } else {
                                task = try BSONDecoder().decode(CypherTask.self, from: job.task)
                            }
                        } catch {
                            return self.eventLoop.makeFailedFuture(error)
                        }
                        
                        return messenger.eventLoop.executeAsync {
                            try await task.onDelayed(on: messenger)
                        }
                    }

                    debugLog("Task failed or none found, stopping processing")
                    self.runningJobs = false
                    return try await EventLoopFuture.andAllComplete(done, on: self.eventLoop).get()
                }
            }
        }

        _ = eventLoop.executeAsync { @MainActor in
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

    public func resume() {
        pausing = nil
        startRunningTasks()
    }
    
    public func restart() -> EventLoopFuture<Void> {
        pause().map(resume)
    }

    public func pause() -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        pausing = promise
        if !runningJobs {
            promise.succeed(())
        }

        return promise.futureResult
    }

    public enum TaskResult {
        case success, delayed, failed(haltExecution: Bool)
    }

    private func runNextJob(in jobs: inout [DecryptedModel<JobModel>]) async throws -> TaskResult {
        debugLog("Available jobs", jobs.count)
        var index = 0
        let initialJob = jobs[0]

        if initialJob.props.isBackgroundTask, jobs.count > 1 {
            findBetterTask: for newIndex in 1..<jobs.count {
                let newJob = jobs[newIndex]
                if !newJob.props.isBackgroundTask {
                    index = newIndex
                    break findBetterTask
                }
            }
        }

        let job = jobs[index]

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
        
        if task.requiresConnectivity, messenger.transport.authenticated != .authenticated {
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
                debugLog("Delaying task for an hour")
                try await job.delayExecution(retryDelay: retryDelay)
                
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
