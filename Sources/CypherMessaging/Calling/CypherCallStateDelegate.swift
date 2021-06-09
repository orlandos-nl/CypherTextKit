import NIO

public struct CypherCallEvent<CallHandle: Equatable> {
    public let event: UserCallAction<CallHandle>
    public let oldState: CallState<CallHandle>
    public let newState: CallState<CallHandle>
}

public protocol CypherCallStateDelegate {
    associatedtype CallHandle: Equatable
    
    func executeAction(
        _ action: CallDelegateAction<CallHandle>?,
        forEvent: CypherCallEvent<CallHandle>
    ) async throws
}

public final class CallManager<Delegate: CypherCallStateDelegate> {
    private let delegate: Delegate
    public private(set) var state: CallState<Delegate.CallHandle> = .idle
    
    public init(delegate: Delegate) {
        self.delegate = delegate
    }
    
    public func executeAction(_ action: UserCallAction<Delegate.CallHandle>) async throws {
        let oldState = state
        let delegateAction = state.executeAction(action)
        let newState = state
        
        let event = CypherCallEvent(
            event: action,
            oldState: oldState,
            newState: newState
        )
        
        return try await delegate.executeAction(delegateAction, forEvent: event)
    }
}
