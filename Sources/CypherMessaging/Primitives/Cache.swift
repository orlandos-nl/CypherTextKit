//
//  SwiftUIView.swift
//  
//
//  Created by Joannis Orlandos on 19/04/2021.
//


public protocol CacheKey {
    associatedtype Value
}

public final class Cache {
    internal init() {}
    
    private var values = [ObjectIdentifier: Any]()
    
    public func read<Key: CacheKey>(_ key: Key.Type) -> Key.Value? {
        values[ObjectIdentifier(key)] as? Key.Value
    }
    
    public func setValue<Key: CacheKey>(_ value: Key.Value, forKey key: Key.Type) {
        values[ObjectIdentifier(key)] = value
    }
    
    public func readOrCreateValue<Key: CacheKey>(forKey key: Key.Type, resolve: () -> Key.Value) -> Key.Value {
        if let value = read(key) {
            return value
        } else {
            let value = resolve()
            setValue(value, forKey: key)
            return value
        }
    }
}
