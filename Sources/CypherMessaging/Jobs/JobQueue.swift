import BSON
import Crypto
import Foundation
import SwiftUI
import NIO

@available(macOS 12, iOS 15, *)
final class JobQueue: ObservableObject {
    public let eventLoop: EventLoop
    unowned private(set) var messenger: CypherMessenger!
    private let database: CypherMessengerStore
    private let databaseEncryptionKey: SymmetricKey
    public private(set) var runningJobs = false
    public private(set) var hasOutstandingTasks = true
    private var pausing: EventLoopPromise<Void>?
    private var jobs: [DecryptedModel<JobModel>]
    private static var taskDecoders = [TaskKey: TaskDecoder]()

    init(messenger: CypherMessenger, database: CypherMessengerStore, databaseEncryptionKey: SymmetricKey) async throws {
        self.eventLoop = messenger.eventLoop
        self.messenger = messenger
        self.database = database
        self.databaseEncryptionKey = databaseEncryptionKey
        self.jobs = try await database.readJobs().asyncMap { job -> (Date, DecryptedModel<JobModel>) in
            let job = job.decrypted(using: databaseEncryptionKey)
            return await (job.scheduledAt, job)
        }.sorted { lhs, rhs in
            lhs.0 < rhs.0
        }.map(\.1)
    }
    
    static func registerTask<T: Task>(_ task: T.Type, forKey key: TaskKey) {
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
        for i in 0..<self.jobs.count {
            if await self.jobs[i].id == job.id {
                self.jobs.remove(at: i)
                return
            }
        }
    }
    
    public func queueTask<T: Task>(_ task: T) async throws {
        let job = try JobModel(
            props: .init(task: task),
            encryptionKey: databaseEncryptionKey
        )
        
        self.jobs.append(job.decrypted(using: databaseEncryptionKey))
        try await database.createJob(job)
        if !self.runningJobs {
            self.startRunningTasks()
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

        func next(in jobs: [DecryptedModel<JobModel>]) async throws {
            debugLog("Looking for next task")
            if jobs.isEmpty {
                debugLog("No more tasks")
                self.runningJobs = false
                self.hasOutstandingTasks = false
                return
            }

            var jobs = jobs

            let result = (try? await runNextJob(in: &jobs)) ?? .failed
            
            if let pausing = self.pausing {
                debugLog("Job finished, pausing started. Stopping further processing")
                self.runningJobs = false
                pausing.succeed(())
                return
            } else {
                switch result {
                case .success, .delayed:
                    return try await next(in: jobs)
                case .failed:
                    let done = await jobs.asyncMap { job -> EventLoopFuture<Void> in
                        let task: Task
                        
                        do {
                            let taskKey = await TaskKey(rawValue: job.taskKey)
                            if let decoder = Self.taskDecoders[taskKey] {
                                task = try await decoder(job.task)
                            } else {
                                task = try await BSONDecoder().decode(CypherTask.self, from: job.task)
                            }
                        } catch {
                            return self.eventLoop.makeFailedFuture(error)
                        }
                        
                        return self.messenger.eventLoop.executeAsync {
                            try await task.onDelayed(on: self.messenger)
                        }
                    }

                    debugLog("Task failed or none found, stopping processing")
                    self.runningJobs = false
                    return try await EventLoopFuture.andAllComplete(done, on: self.eventLoop).get()
                }
            }
        }

        _ = eventLoop.executeAsync {
            // Lock in the current queue
            let jobs = self.jobs
            if self.jobs.isEmpty {
                debugLog("No jobs to run")
                self.hasOutstandingTasks = false
                self.runningJobs = false
            } else {
                var hasUsefulTasks = false
                
                findUsefulTasks: for job in jobs {
                    if let delayedUntil = await job.delayedUntil, delayedUntil >= Date() {
                        if await !job.props.isBackgroundTask {
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
                    try await next(in: jobs)
                    // If offline, don't restart this. That can cause infinite loops
                    if self.messenger?.transport.authenticated == .authenticated {
                        self.startRunningTasks()
                    }
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
        case success, delayed, failed
    }

    private func runNextJob(in jobs: inout [DecryptedModel<JobModel>]) async throws -> TaskResult {
        var index = 0
        let initialJob = jobs[0]

        if await initialJob.props.isBackgroundTask, jobs.count > 1 {
            findBetterTask: for newIndex in 1..<jobs.count {
                let newJob = jobs[newIndex]
                if await !newJob.props.isBackgroundTask {
                    index = newIndex
                    break findBetterTask
                }
            }
        }

        let job = jobs.remove(at: index)

        debugLog("Running job", await job.props)

        if let delayedUntil = await job.delayedUntil, delayedUntil >= Date() {
            debugLog("Task was delayed into the future")
            return .delayed
        }
        
        let task: Task
        
        let taskKey = await TaskKey(rawValue: job.props.taskKey)
        if let decoder = Self.taskDecoders[taskKey] {
            task = try await decoder(job.props.task)
        } else {
            task = try await BSONDecoder().decode(CypherTask.self, from: job.task)
        }
        
        guard let messenger = self.messenger else {
            throw CypherSDKError.appLocked
        }
        
        if task.requiresConnectivity, messenger.transport.authenticated != .authenticated {
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
                await job.didRetry(retryDelay: retryDelay)
                
                if let maxAttempts = maxAttempts, await job.attempts >= maxAttempts {
                    try await self.cancelJob(job)
                    return .success
                }

                try await self.database.updateJob(job.encrypted)
                return .delayed
            case .always:
                return .delayed
            case .never:
                try await self.dequeueJob(job)
                return .failed
            }
        }
    }
}
