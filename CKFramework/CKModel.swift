
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
 
 
 CKModel.swift
 
 Internal constants, classes, extensions.
 
 */


import CloudKit



// UserDefaults keypath prefixes
internal struct CKDefaults {
    
    // UserDefaults keypath to store entity last sync date (appends entity id)
    internal static let kEntityLastSyncPrefix = "com.cloudkit.controller.lastsync.entity."
    
    // UserDefaults keypath to store deleted, but not synced entities.
    // This one is required for DeleteQueue managed by CKFramework
    internal static let kDeletedDictionary = "com.cloudkit.controller.deleted"
}


// CloudKit RecordTypes
internal struct CKRecordTypes  {
    internal static let deleteQueue = "DeleteQueue"
    internal static let devices = "Device"
}


// DeleteQueue Keys
internal struct CKDeleteQueueKeys {
    internal static let recordType = "dq_recordType"
    internal static let recordId = "dq_recordID"
    internal static let deviceId = "dq_deviceID"
}





// Inner Placeholder class used to store deleted entities' syncID
// Used if we delete object while there was no internet connection
// Once we're online, we instantiate fake CKEntity objects to
// pass them over to iCloudDelete func.
// Must be KVC-compliant, hence the dynamic keywords (naturally only
// required for syncID property)

internal class DeletedEntityPlaceholder : NSObject, CKEntity {
    
    internal dynamic var syncID : String = ""
    internal dynamic static var recordType: String = ""
    internal dynamic static var mappingDictionary: [String : String] = [:]
    
    convenience init(recordType: String, syncId: String) {
        self.init()
        
        DeletedEntityPlaceholder.recordType = recordType
        self.syncID = syncId
    }
}


// CKEntity Keys
internal struct CKEntityKeys {
    internal static let recordType = "recordType"
    internal static let mappingDictionary = "mappingDictionary"
    internal static let referenceLists = "refLists"
    internal static let references = "references"
}


// Local enum, used as a substitute for .orderedAscending/Descending cases
// to determine whether particular local date is newer that remote date
// which means that either local or remote object must be updated.
// Sample use:
// let syncState = EntitySyncState(rawValue: localDate.compare(remoteDate).rawValue)

internal enum EntitySyncState : Int {
    case remoteNewer = -1
    case same
    case localNewer
}






/// Generic proxy-class used for iCloud proxy, currently only Swift3 compatible.
internal class CloudKitInterface<T> : CKEntityFunctions where T:CKEntity, T:NSObjectProtocol{
    
    private var entity : T
    
    init(for entity: T){
        self.entity = entity
    }
    
    func save() {
        cloudKitInstance?.iCloudSave(entity)
    }
    
    func saveAndWait() {
        _ = cloudKitInstance?.saveRecordSync(entity: entity, submitBlock: nil, completionHandler: cloudKitInstance?.delegate.entityDidSaveToCloudCallback)
    }
    
    func delete() {
        cloudKitInstance?.iCloudDelete(entity)
    }
    
    func saveKeys(_ keys: [String]) {
        cloudKitInstance?.iCloudSaveKeys(entity, keys: keys)
    }
    
    func saveKeysAndWait(_ keys: [String]) {
        cloudKitInstance?.iCloudSaveKeysAndWait(entity, keys: keys)
    }
    
    func update (fromRemote record: CKRecord, fetchReferences fetch: Bool = false) {
        cloudKitInstance?.updateEntity(self as! CKEntity, fromRemote: record, fetchReferences: fetch)
    }
}




