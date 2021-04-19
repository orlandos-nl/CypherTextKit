import BSON
import Crypto
import Foundation
import SwiftUI
import NIO

public final class JobQueue: ObservableObject {
    public let eventLoop: EventLoop
    unowned private(set) var messenger: CypherMessenger!
    private let database: CypherMessengerStore
    private let databaseEncryptionKey: SymmetricKey
    public private(set) var runningJobs = false
    public private(set) var hasOutstandingTasks = true
    private var pausing: EventLoopPromise<Void>?
    private var jobs = [DecryptedModel<Job>]()
    private static var taskDecoders = [TaskKey: TaskDecoder]()

    init(messenger: CypherMessenger, database: CypherMessengerStore, databaseEncryptionKey: SymmetricKey) {
        self.eventLoop = messenger.eventLoop
        self.messenger = messenger
        self.database = database
        self.databaseEncryptionKey = databaseEncryptionKey

        database.readJobs().whenSuccess { jobs in
            let jobs = jobs.map { job in
                job.decrypted(using: databaseEncryptionKey)
            }.sorted { lhs, rhs in
                lhs.scheduledAt < rhs.scheduledAt
            }
            
            self.jobs = jobs
        }
    }
    
    static func registerTask<T: Task>(_ task: T.Type, forKey key: TaskKey) {
        taskDecoders[key] = { document in
            try BSONDecoder().decode(task, from: document)
        }
    }
    
    func cancelJob(_ job: DecryptedModel<Job>) -> EventLoopFuture<Void> {
        // TODO: What if the job is cancelled while executing and succeeding?
        return dequeueJob(job)
    }
    
    func dequeueJob(_ job: DecryptedModel<Job>) -> EventLoopFuture<Void> {
        return database.removeJob(job.encrypted).map {
            self.jobs.removeAll { $0.id == job.id }
        }
    }
    
    public func queueTask<T: Task>(_ task: T) -> EventLoopFuture<Void> {
        do {
            let job = try Job(
                props: .init(task: task),
                encryptionKey: databaseEncryptionKey
            )
            
            self.jobs.append(job.decrypted(using: databaseEncryptionKey))
            return database.createJob(job).map {
                if !self.runningJobs {
                    self.startRunningTasks()
                }
            }
        } catch {
            return eventLoop.makeFailedFuture(error)
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

        @discardableResult
        func next(in jobs: [DecryptedModel<Job>]) -> EventLoopFuture<Void> {
            debugLog("Looking for next task")
            if jobs.isEmpty {
                debugLog("No more tasks")
                self.runningJobs = false
                self.hasOutstandingTasks = false
                return self.eventLoop.makeSucceededVoidFuture()
            }

            var jobs = jobs

            return runNextJob(in: &jobs).recover { _ in
                return .failed
            }.flatMap { result in
                if let pausing = self.pausing {
                    debugLog("Job finished, pausing started. Stopping further processing")
                    self.runningJobs = false
                    pausing.succeed(())
                    return self.eventLoop.makeSucceededVoidFuture()
                } else {
                    switch result {
                    case .success, .delayed:
                        return next(in: jobs)
                    case .failed:
                        let done = jobs.map { job -> EventLoopFuture<Void>in
                            let task: Task
                            
                            do {
                                let taskKey = TaskKey(rawValue: job.props.taskKey)
                                if let decoder = Self.taskDecoders[taskKey] {
                                    task = try decoder(job.props.task)
                                } else {
                                    task = try BSONDecoder().decode(CypherTask.self, from: job.task)
                                }
                            } catch {
                                return self.eventLoop.makeFailedFuture(error)
                            }
                            
                            return task.onDelayed(on: self.messenger)
                        }

                        debugLog("Task failed or none found, stopping processing")
                        self.runningJobs = false
                        return EventLoopFuture.andAllComplete(done, on: self.eventLoop)
                    }
                }
            }
        }

        // Lock in the current queue
        let jobs = self.jobs
        if self.jobs.isEmpty {
            debugLog("No jobs to run")
            self.hasOutstandingTasks = false
            self.runningJobs = false
        } else {
            var hasUsefulTasks = false
            
            findUsefulTasks: for job in jobs {
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
            
            next(in: jobs).map {
                // If offline, don't restart this. That can cause infinite loops
                if self.messenger?.transport.authenticated == .authenticated {
                    self.startRunningTasks()
                }
            }.whenFailure { error in
                debugLog("Job queue error", error)
                self.runningJobs = false
                self.pausing?.succeed(())
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

    private func runNextJob(in jobs: inout [DecryptedModel<Job>]) -> EventLoopFuture<TaskResult> {
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

        let job = jobs.remove(at: index)

        debugLog("Running job", job.props)

        if let delayedUntil = job.delayedUntil, delayedUntil >= Date() {
            debugLog("Task was delayed into the future")
            return self.eventLoop.makeSucceededFuture(.delayed)
        }
        
        let task: Task
        
        do {
            let taskKey = TaskKey(rawValue: job.props.taskKey)
            if let decoder = Self.taskDecoders[taskKey] {
                task = try decoder(job.props.task)
            } else {
                task = try BSONDecoder().decode(CypherTask.self, from: job.task)
            }
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
        
        guard let messenger = self.messenger else {
            return self.eventLoop.makeFailedFuture(CypherSDKError.appLocked)
        }
        
        if task.requiresConnectivity, messenger.transport.authenticated != .authenticated {
            return self.eventLoop.makeFailedFuture(CypherSDKError.offline)
        }

        return task.execute(on: messenger).hop(
            to: messenger.eventLoop
        ).flatMap {
            self.dequeueJob(job).map {
                TaskResult.success
            }
        }.flatMapError { error -> EventLoopFuture<JobQueue.TaskResult> in
            debugLog("Job error", error)

            switch task.retryMode.raw {
            case .retryAfter(let retryDelay, let maxAttempts):
                debugLog("Delaying task for an hour")
                job.delayedUntil = Date().addingTimeInterval(retryDelay)
                job.attempts += 1
                
                if let maxAttempts = maxAttempts, job.attempts >= maxAttempts {
                    return self.cancelJob(job).map {
                        return TaskResult.success
                    }
                }

                return self.database.updateJob(job.encrypted).map {
                    return TaskResult.delayed
                }
            case .always:
                return self.eventLoop.makeSucceededFuture(.delayed)
            case .never:
                return self.dequeueJob(job).map {
                    return .failed
                }
            }
        }
    }
}
