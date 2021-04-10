public enum UserCallAction<CallHandle: Equatable> {
    public enum ActionType {
        // Start call represents both accept and start call
        case startCall
        
        // End call represents both decline and end call
        case endCall
    }
    
    case currentUser(to: CallHandle, ActionType)
    case otherUser(from: CallHandle, ActionType)
    
    public var otherUser: CallHandle {
        switch self {
        case let .currentUser(to: handle, _):
            return handle
        case let .otherUser(from: handle, _):
            return handle
        }
    }
}

public enum CallDelegateAction<CallHandle: Equatable> {
    /// Prepare audio, but no message
    case prepareCall(with: CallHandle)
    
    /// Send an endCall message & shut down audio
    case endCall(with: CallHandle)
    
    /// Send a startCall message, offering a call
    case startCall(with: CallHandle)
    
    /// Accept a call, and prepare audio
    case acceptCall(with: CallHandle)
    
    /// Decline the call, we're too busy
    case tooManyCallers(to: CallHandle)
    
    /// Case hang up one call, shut down audio, then accept another call and enable audio
    case tuple(hangUp: CallHandle, accept: CallHandle)
}

public enum CallState<CallHandle: Equatable>: Equatable {
    case idle
    case active(CallActiveState<CallHandle>)
    case activeAndIncoming(CallActiveState<CallHandle>, CallHandle)
    
    public var isActive: Bool {
        if case .idle = self {
            return false
        } else {
            return true
        }
    }
    
    public mutating func executeAction(_ action: UserCallAction<CallHandle>) -> CallDelegateAction<CallHandle>? {
        switch (self, action) {
        case let (.idle, .currentUser(to: handle, .startCall)):
            self = .active(.calling(handle))
            return .startCall(with: handle)
        case let (.idle, .otherUser(from: handle, .startCall)):
            // Other user is calling us
            self = .active(.beingCalled(by: handle))
            return nil
        case (.idle, .otherUser(from: _, .endCall)), (.idle, .currentUser(to: _, .endCall)):
            // Invalid transition. We're not in a call.
            return nil
        case let (.active(activeState), .currentUser(to: recipient, .endCall)):
            if activeState.handle == recipient {
                // We're ending the call
                self = .idle
                return .endCall(with: recipient)
            } else {
                // Invalid transition. We're not in a call.
                return nil
            }
        case let (.active(.beingCalled(by: currentCaller)), .currentUser(to: recipient, .startCall)):
            if currentCaller == recipient {
                // We're trying to call
                self = .active(.inCall(recipient))
                return .acceptCall(with: recipient)
            } else {
                // Cannot call a person
                return nil
            }
        case let (.active(currentCall), .otherUser(from: sender, .endCall)):
            if currentCall.handle == sender {
                // Other user ended the call
                self = .idle
                return .endCall(with: sender)
            } else {
                // Invalid transition. Other user isn't in a call with us
                return nil
            }
        case let (.active(.calling(otherUser)), .otherUser(from: sender, .startCall)) where otherUser == sender:
            // Other user accepts our call
            self = .active(.inCall(sender))
            return .prepareCall(with: sender)
        case let (.active(activeCall), .otherUser(from: sender, .startCall)) where activeCall.handle != sender:
            // Other user starts a call with us. We have to pick.
            self = .activeAndIncoming(activeCall, sender)
            return nil
        case (.active, .currentUser(to: _, .startCall)):
            // Invalid transition. Cannot start a call when in a call
            return nil
        case let (.active(currentCall), .otherUser(from: sender, .startCall)):
            if sender == currentCall.handle {
                // Invalid transition. Other user is already calling us
                return nil
            } else {
                self = .activeAndIncoming(currentCall, sender)
                return nil
            }
        case let (.activeAndIncoming(activeCall, newCaller), .currentUser(to: recipient, .startCall)):
            if case .beingCalled(by: recipient) = activeCall {
                // Hang up the second caller, accept the first caller
                self = .active(.inCall(newCaller))
                return .tuple(hangUp: recipient, accept: activeCall.handle)
            } else if recipient == newCaller {
                // Hang up the first aller, accept the second caller
                self = .active(.inCall(recipient))
                return .tuple(hangUp: activeCall.handle, accept: recipient)
            } else {
                // Invalid transition. Cannot accept this caller
                // Either we're already calling them, or they're not calling us
                return nil
            }
        case let (.activeAndIncoming(activeCall, newCaller), .currentUser(to: recipient, .endCall)):
            if case .beingCalled(by: recipient) = activeCall {
                // Hang up the first caller
                self = .active(.calling(newCaller))
                return .endCall(with: recipient)
            } else if recipient == newCaller {
                // Hang up the second caller
                self = .active(activeCall)
                return .endCall(with: recipient)
            } else {
                // Invalid transition. This person isn't calling us.
                self = .idle
                return nil
            }
        case let (.activeAndIncoming(activeCall, newCaller), .otherUser(from: sender, .startCall)):
            if case .calling(sender) = activeCall {
                // We were calling someone, they accepted
                self = .activeAndIncoming(.inCall(sender), newCaller)
                return .prepareCall(with: sender)
            } else if sender == newCaller {
                // New caller cannot accept their own call
                return nil
            } else {
                // A third caller started a call. We're popular!
                return .tooManyCallers(to: sender)
            }
        case let (.activeAndIncoming(activeCall, newCaller), .otherUser(from: sender, .endCall)):
            if activeCall.handle == sender {
                // First user hung up/declined
                self = .active(.beingCalled(by: newCaller))
                return nil
            } else if sender == newCaller {
                // New caller stopped
                self = .active(activeCall)
                return nil
            } else {
                // A third caller, not connected, stopped calling or sent an invalid message
                return nil
            }
        }
    }
}

public enum CallActiveState<CallHandle: Equatable>: Equatable {
    case beingCalled(by: CallHandle)
    case calling(CallHandle)
    case inCall(CallHandle)
    
    public var handle: CallHandle {
        switch self {
        case let .beingCalled(by: handle):
            return handle
        case let .calling(handle):
            return handle
        case let .inCall(handle):
            return handle
        }
    }
}
