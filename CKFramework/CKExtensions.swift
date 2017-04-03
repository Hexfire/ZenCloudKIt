/***********************************************************************
 
 CKFramework v.0.1 (beta)
 
 CKFramework is a framework intended to facilitate the use of native
 CloudKit framework, rendering unified interface which could be
 implemented in projects that employ CoreData (though CoreData is not
 a requirement), making it much easier for developer to implement
 basic (as well as more advanced) operations, such as saving, deleting
 and syncing objects to/with CloudKit, including references and push
 notifications management.
 
 Currently is in beta. Some issues are known and pending update.
 
 Created by Hexfire (trancing@gmail.com) from 11/2016 to 02/2017.
 
 ***********************************************************************
 
 
 CKExtensions.swift
 
 Swift extensions, for inner and outer use.
 
 */


import Foundation
import CloudKit


internal extension CKEntity {
    
    internal static var lastSyncKey : String {
        return CKDefaults.kEntityLastSyncPrefix + (Self.self as! NSObject.Type).className()
    }
    
    internal func getTypeOfProperty (name: String) -> String? {
        if let managedSelf = self as? NSManagedObject {
            if let attr = managedSelf.entity.relationshipsByName[name] {
                return attr.destinationEntity?.managedObjectClassName ?? nil
            }
        }
        
        var type: Mirror = Mirror(reflecting: self)
        
        func formatOptionalType(_ string: String) -> String {
            guard string.characters.last == ">" else { return string }
            var processedString = String(string.characters.dropLast())
            
            processedString = processedString.replacingOccurrences(of: "ImplicitlyUnwrappedOptional<", with: "")
            processedString = processedString.replacingOccurrences(of: "Optional<", with: "")
            
            return processedString
        }
        
        for child in type.children {
            if child.label! == name {
                return formatOptionalType(String(describing: type(of: child.value)))
            }
        }
        while let parent = type.superclassMirror {
            for child in parent.children {
                if child.label! == name {
                    return formatOptionalType(String(describing: type(of: child.value)))
                }
            }
            type = parent
        }
        return nil
    }

}


public extension CKEntity  {
    public static func predicateForId(syncId: String) -> NSPredicate {
        return NSPredicate(format: "\(Self.securedSyncKey!) = %@", syncId)
    }
    
    public static var securedSyncKey : String! {
        return Self.self.syncIdKey ?? cloudKitInstance?.syncIdKey
    }
    
    public static var securedChangeDateKey : String! {
        return Self.self.changeDateKey ?? cloudKitInstance?.changeDateKey
    }
    
    
    public var iCloud: CKEntityFunctions {
        return CloudKitInterface(for: self)
    }
    
    public var equalityPredicate : NSPredicate! {
        
        guard let syncIdKey = type(of:self).syncIdKey ?? cloudKitInstance?.syncIdKey
            else { return nil }
        
        return NSPredicate(format: "\(syncIdKey) = %@", (self as! NSObject).value(forKey: syncIdKey) as! String)
        
    }
    
    
    public static func syncEntities(forced: Bool = false) {
        guard
            cloudKitInstance != nil,
            cloudKitInstance.container != nil,
            cloudKitInstance.delegate != nil
            else {
                print("[CK SYNC] OPERATION FAILURE: CKController has not been properly initialized!")
                return
        }
        
        cloudKitInstance.processDeleteQueue()
        cloudKitInstance.syncEntities(allEntitiesOfType: cloudKitInstance.delegate.allEntities(ofType: Self.self)! as? [Self], forcedSync: forced)
    }
    
    
    public static func syncEntities(fromList list: [Self], forced: Bool = false) {
        
        guard
            cloudKitInstance != nil,
            cloudKitInstance.container != nil,
            cloudKitInstance.delegate != nil
            else {
                print("[CK SYNC] OPERATION FAILURE: CKController has not been properly initialized!")
                return
        }
        
        cloudKitInstance.syncEntities(allEntitiesOfType: list, forcedSync: forced)
    }
    
    
}
