//
//  SwiftUIView.swift
//  
//
//  Created by Joannis Orlandos on 19/04/2021.
//

typealias CacheActor = MainActor

public protocol CacheKey {
    associatedtype Value
}

@CacheActor public final class Cache: Sendable {
    internal init() {}
    
    private var values = [ObjectIdentifier: Any]()
    
    @CacheActor
    public func read<Key: CacheKey>(_ key: Key.Type) -> Key.Value? {
        values[ObjectIdentifier(key)] as? Key.Value
    }
    
    @CacheActor
    public func setValue<Key: CacheKey>(_ value: Key.Value, forKey key: Key.Type) {
        values[ObjectIdentifier(key)] = value
    }
    
    @CacheActor
    public func readOrCreateValue<Key: CacheKey>(forKey key: Key.Type, resolve: @Sendable () -> Key.Value) -> Key.Value {
        if let value = read(key) {
            return value
        } else {
            let value = resolve()
            setValue(value, forKey: key)
            return value
        }
    }
}
