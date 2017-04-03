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
 
 Created by Hexfire (trancing@gmail.com) from 11/2016 to 01/2017.
 
 ***********************************************************************
 
 
 CKFramework.swift
 
 Main class which contains core functionality.
 
*/



import Cocoa
import CloudKit

// Project-scope variable to CK controller instance
internal var cloudKitInstance : CloudKitFramework!


// Variable that defines whether full sync cycle is needed to synchronize changes
// made to local objects. Gets set to true if there was no internet connection while
// processing entities. E.g. deleting or creating new objects w/o network access
// means app-level synchronization is pending, rendering flag true.
internal var syncPending = false


/* IMPLEMENTATION */


// Although mainly aimed at Swift 3 developers, major part of CKFramework 
// functionality can be successfully bridged to Objective-C, hence the class
// is derived from NSObject to allow Obj-C compatibility

@objc public class CloudKitFramework : NSObject {
    
    
// MARK: - Public Interface
    
    // delegate property is required for CKFramework to function
    public var delegate : CloudKitProtocol!
    
    // In debug mode all core sync actions are logged. Defaults to true.
    public var debugMode : Bool = true
    
    // public singleton accessor
    @objc public static var sharedInstance = CloudKitFramework()
    
    // Registered entities we are about to work with (sync)
    public var entities : [CKEntity.Type]!
    
    
// MARK: - Base Configuration
    
    
    // Sync ID key of all registered entities. It has secondary
    // priority compared to intrinsic/individual syncID entity property.
    internal var syncIdKey : String! = "syncID"
    
    // Similarly, changeDateKey is the second place CKFramework will
    // seek to determine change date key of an entity.
    // If an entity has changeDateKey defined, it will be taken.
    internal var changeDateKey : String! = "changeDate"
    
    // Unique Device identifier. Required to successfully
    // sync with multiple devices. Typically, a UUID string.
    internal var deviceId : String!
    
    // CloudKit RecordType for Devices. This is where all devices
    // that use your app will be registered in the CloudKit
    internal var devicesRecordType : String! = "Device"
    
    // Array of syncId exception keys which tell CKFramework
    // to ignore objects possessing them.
    internal var ignoreKeys : [String]!
    
    // Array of registered devices, filled internally by CKFramework.
    // Required to successfully manage update/deletion of CK objects.
    internal var allDevices = [String]()
    
    // Internal flag which can immediately lock sync functionality
    // Exposed to client via lockSync() method. Toggled back and forth.
    internal var isSyncLocked = false // Permit syncing
    

// MARK: - CloudKit internal objects
    

    // Container is inherently a source of all things. Initialized with ID
    // and provides access to database with accessibility scope
    internal var container : CKContainer!
    
    // Database represents actual host of CKRecord objects
    // Can be either private or public. Set during initialization
    internal var database : CKDatabase!
    
    
// MARK: - Mechanics
    
    
    // Timer object which monitors connectivity and manages sync cycles
    internal var connectionCheckTimer : Timer!
    
    // Push notifications may fail, so the timer is used to forcecheck
    // Delete Queue state. This feature may be included in setup
    // configuration for the sake of user control in the future updates.
    internal var deleteQueueTimer : Timer!
    
    
// MARK: - Queues
    
    // Dedicated queues for each registered entity
    private var queues = [DispatchQueue]()
    
    // Internal use background queue
    private let background_queue = DispatchQueue(label: "background_queue", attributes: DispatchQueue.Attributes.concurrent)
    
    
/* --------------------------------------------- */


// MARK: - CORE - Implementation
    
    
    /// Private constructor. We have genuine Singleton here.
    fileprivate override init(){}

    
    /// One of the first steps is to fetch list of registered devices – and register ours.
    /// This is crucial when more than two devices interact with the same database.
    /// For instance, if you have deleted an object locally, respective record must be
    /// created remotely to inform all other devices concerning deleted record.
    
    internal func fetchListOfDevices() {
        
        let query = CKQuery.init(recordType: CKRecordTypes.devices, predicate: NSPredicate(value: true))
        let operation = CKQueryOperation.init(query: query)
        
        var localDeviceSaved = false
        
        self.allDevices.removeAll()
        
        background_queue.async(execute: { [unowned self] in
            let sema = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .default).async(execute: {
                
                operation.queuePriority = .veryHigh
                operation.qualityOfService = .default
                operation.recordFetchedBlock = { record in
                    if record.recordID.recordName != self.deviceId {
                        self.allDevices.append(record.recordID.recordName)
                    } else {
                        localDeviceSaved = true
                    }
                }
                
                operation.completionBlock = {
                    
                    if !localDeviceSaved {
                        let record = CKRecord.init(recordType: CKRecordTypes.devices, recordID: CKRecordID.init(recordName: self.deviceId!))
                        
                        self.database.save(record, completionHandler: { (rec, error) in
                            if rec != nil {
                                if self.debugMode { print("[CK DEVICE INIT] Device ID initialized.") }
                            } else {
                                if self.debugMode { print("[CK DEVICE INIT] Failed to initialize device ID: \(String(describing: error)) - record: \(String(describing: rec))") }
                            }
                        })
                    } else {
                        if self.debugMode { print("[CK DEVICE INIT] Device ID initialized.") }
                    }
                    
                    _ = sema.signal()
                }
            })
            
            self.database.add(operation)
            
            sema.wait()
            
            cloudKitInstance.processDeleteQueue()
            cloudKitInstance.scheduleSyncCheck()
            
        })
        
    }
    
    
    
    // Public func, allows to quickly postpone/disable sync functionality
    // on framework-level without the need to come up with multiple flag-checks
    // across the app before each use of .save() or .delete() calls.
    
    @objc public func lockSync(locked: Bool) {
        isSyncLocked = locked
    }
    
    
  
// MARK: - Public - Initialization
    
    /* 
     
     func setup(...)
     
     This is where things start off.
     
     
     Parameters:
     
        container: String
     
                - container ID
     
        type: .private/.public
     
                - database scope
     
        syncIdKey: String 
     
                - name of the property to seek in every CKEntity class for sync ID.
                If CKEntity class has its own syncIdKey defined, it will be taken as being
                of higher priority. Generally it's more convenient to have identical
                syncId property across all entities than that defined in each class.

        changeDateKey: String
     
                - as with syncIdKey, this parameter defines change date key for all
                registered entities. Along the same lines, you can define class-specific
                changeDateKey for each CKEntity class.
     
        entities: [CKEntity.Type]
                
                - array of CKEntity classes which will be used by CKFramework.
                NOTE that implementing CKEntity protocol is not(!) enough for entity to be synced.
                It is also required to register all the entities within CKFramework by passing
                them here.
     
        ignoreKeys: [String]!,
     
                - optional array of syncId exceptions. CKEntity object with one of these values
                as syncId will be ignored by CKFramework if passed over for sync processing.
     
        deviceId: String,
     
                 - required device ID. 
                For usage refer to variable definitions
     
 
    */
    
    
    @objc public func setup(container: String,
                      ofType type: CKContainerType,
                      syncIdKey: String!,
                      changeDateKey: String!,
                      entities: [CKEntity.Type],
                      ignoreKeys : [String]!,
                      deviceId: String)
    {
        
        
        // Composing list of misimplemented entities, i.e. the ones
        // which have either recordType or mappingDictionary fields undefined
        let misimplemented = entities.filter {
            let item = ($0 as! NSObject.Type);

            return
                item.value(forKey: CKEntityKeys.recordType) as? String ?? "" == "" ||
                (item.value(forKey: CKEntityKeys.mappingDictionary) as? [String:String] ?? [String:String]())!.count == 0
        }
        
        
        // If any entity was not implemented, init fails.
        if misimplemented.count > 0 {
            if self.debugMode { print("[CK INIT] FAILURE. Following entities have not been properly initialized: \(misimplemented)") }
            return
        }
        
        
        // Define queue for each entity
        for entity in entities {
            self.queues.append(DispatchQueue.init(
                label: "cloudkitframework.entity.queue.\(entity.recordType)",
                qos: .init(qosClass: .userInitiated, relativePriority: 0),
                attributes: DispatchQueue.Attributes.concurrent))
        }
        
        
        tryBlock {
            self.container = CKContainer(identifier: container)
            self.database = type == .public
                ? self.container.publicCloudDatabase
                : self.container.privateCloudDatabase
        }
        
        
        if self.container == nil {
            print("[CK INIT] FAILURE. Container cannot be initialized")
            return
        }
        
        
        self.syncIdKey = syncIdKey
        self.changeDateKey = changeDateKey
        self.entities = entities
        self.deviceId = deviceId
        self.ignoreKeys = ignoreKeys
        

        self.background_queue.async(flags: .barrier, execute:  {
            
            self.container.accountStatus { (status, error) in
                
                switch status {
                    
                case .noAccount, .restricted, .couldNotDetermine:
                    if self.debugMode { print("[CK INIT] ACCESS ERROR! \(String(describing: error)) (\(String(describing: status)))") }
                    return
                    
                default:
                    if self.debugMode { print("[CK INIT] CLOUDKIT ACCESS GRANTED!") }
                    DispatchQueue.global(qos: .utility).async {
                        self.fetchListOfDevices()
                        self.subscribe()
                    }
                    
                }
                
                
            }
        })
        
        
        cloudKitInstance = self
        
        if self.debugMode { print("[CK INIT] CKController initialized") }

    }
    
    
// MARK:  Subscriptions
    
    internal func subscribe() {
        
        background_queue.async(execute: {
            
            self.removeSubscriptions()
            
            if #available(OSX 10.12, *) {
                
                var recordTypes = self.entities.map({$0.self.recordType})
                recordTypes.append(CKRecordTypes.deleteQueue)
                
                for recordType in recordTypes {
                    
                    let subscription = CKSubscription(recordType: recordType, predicate: NSPredicate.init(value: true),
                                                      options: recordType == CKRecordTypes.devices ? .firesOnRecordCreation :
                                                        [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
                    
                    let notificationInfo = CKNotificationInfo()
                    notificationInfo.shouldBadge = false
                    notificationInfo.soundName = ""
                    notificationInfo.shouldSendContentAvailable = false
                    
                    subscription.notificationInfo = notificationInfo
                    
                    self.database.save(subscription, completionHandler: { (sub, error) in })
                    
                }
            } else {
                
                var recordTypes = self.entities.map({$0.self.recordType})
                recordTypes.append(CKRecordTypes.deleteQueue)
                
                for recordType in recordTypes {
                    
                    let subscription = CKSubscription(recordType: recordType, predicate: NSPredicate.init(value: true),
                                                      options: recordType == CKRecordTypes.devices ? .firesOnRecordCreation :
                                                        [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
                    
                    let notificationInfo = CKNotificationInfo()
                    notificationInfo.shouldBadge = true
                    notificationInfo.soundName = ""
                    notificationInfo.shouldSendContentAvailable = false
                    
                    subscription.notificationInfo = notificationInfo
                    
                    self.database.save(subscription, completionHandler: { (sub, error) in })
                    
                    
                }
                
            }
            
            print("[CK INIT] Did finish subscription")
            
            
        })
        
    }
    
    
    // Remove subscriptions
    
    
    internal func removeSubscriptions() {
        
        let sema = DispatchSemaphore(value: 0)
        
        self.database.fetchAllSubscriptions(completionHandler: { (subscriptions, err) in
            if err == nil {
                if subscriptions?.count == 0 {
                    sema.signal()
                } else {
                    for (i, sub) in subscriptions!.enumerated() {
                        self.database.delete(withSubscriptionID: sub.subscriptionID, completionHandler: { (subId, error) in
                            if self.debugMode { print(error != nil ? "[CK OPERATION] Couldn't delete subscription at startup" : "[CK OPERATION] Subscription deleted successfully") }
                            
                            if i == subscriptions!.count-1 {
                                sema.signal()
                            }
                        })
                    }
                }
            } else {
                sema.signal()
            }
        })
        
        _ = sema.wait()
        
    }
    

    
// MARK: Sync state validation
    
    
    /// Schedule connection and delete queue checks
    ///
    internal func scheduleSyncCheck() {
        
        connectionCheckTimer?.invalidate()
        deleteQueueTimer?.invalidate()
        
        connectionCheckTimer = Timer.init(timeInterval: 60, target: self, selector: #selector(self.validateSync), userInfo: nil, repeats: true)
        deleteQueueTimer = Timer.init(timeInterval: 60, target: self, selector: #selector(self.processDeleteQueue), userInfo: nil, repeats: true)
        
    }
    
    
    /// Function that checks if full sync cycle is pending. 
    /// This check is performed before any regular sync task.
    ///
    internal func validateSync() -> Bool {
        if isSyncLocked { return false }
        if CKReachability.isConnectedToNetwork() {
            if syncPending {
                
                syncPending = false
                
                if let deletedList = UserDefaults.standard.dictionary(forKey: CKDefaults.kDeletedDictionary) as? [String : String] {
                    for e in deletedList.map({ DeletedEntityPlaceholder.init(recordType: $0.value, syncId: $0.key) }) {
                        cloudKitInstance.iCloudDelete(e)
                    }
                    
                    UserDefaults.standard.set([String:String](), forKey: CKDefaults.kDeletedDictionary)
                }
                
                
                for type in self.entities {
                    type.syncEntities()
                }
                
                processDeleteQueue()
            }
        } else {
            syncPending = true
        }
        
        return !syncPending
    }
    
    
    /// DeleteQueue is a special table in CloudKit database that contains references
    /// to deleted objects. These references relate to all registered devices
    /// (one record each). To process delete queue means find all references related
    /// to device in use and pass these references to client for deletion. This is
    /// crucial
    ///
    internal func processDeleteQueue() {
        
        if isSyncLocked {
            if self.debugMode { print("[CK SYNC FAILURE] Sync locked. Enable sync in the app to allow syncing") }
            return
        }
        
        
        let query = CKQuery.init(recordType: CKRecordTypes.deleteQueue, predicate: NSPredicate(format: "\(CKDeleteQueueKeys.deviceId) = %@", self.deviceId))
        let operation = CKQueryOperation.init(query: query)
        
        var finishSyncRecord : CKRecord!
        var deletedRecords = [CKDeleteInfo]()
        
        
        operation.queuePriority = .normal
        operation.qualityOfService = .default
        
        operation.recordFetchedBlock = { [unowned self] record in
            
            self.background_queue.async(flags: .barrier, execute: { [unowned self] in
                if let recordType = self.entities.first (where: { $0.self.recordType == record[CKDeleteQueueKeys.recordType] as? String }) {
                    deletedRecords.append(CKDeleteInfo.init(entityType: recordType.self, syncId: record[CKDeleteQueueKeys.recordId] as! String))
                }
                
                finishSyncRecord = record
                
                
                self.delegate.syncDidFinish(for: nil, newRecords: [], updatedRecords: [], deletedRecords: deletedRecords, finishSync: {
                    self.database.delete(withRecordID: finishSyncRecord.recordID, completionHandler: { (recordId, error) in
                        if error == nil {
                            if self.debugMode { print("[CK OPERATION] Deleted record \(record) from queue") }
                        } else {
                            if self.debugMode { print("[CK OPERATION] Failed to process record \(record) from DELETE QUEUE: \(error!)") }
                        }
                    })
                })
            })
        }
        
        self.database.add(operation)
        
    }
    

    
    // MARK: - CORE (PRIVATE) - Save function
    
    
    /*
     
     func saveRecordSync(...)
     
        Principal save function. Saves an object to CloudKit synchronuously
        using static mapping dictionoary, provided with each entity class.
     
     
     Parameters:
     
        entity: CKEntity
     
                - CKEntity object to save, i.e. an NSObject-derived instance,
                with essential CKEntity properties implemented.
     
     
        preventReferenceCycle: Bool (defaults to false)
     
                - called internally (recursively) to prevent reference cycle.
                I.e., if A has reference to B and B has reference to A, it is
                necessary for A to establish two-way reference to B but without A
                being saved repeatedly, which means we save both A and B (as
                A-referenced object) to CloudKit, but only references of A are saved
                as CKRecords and as CKReference objects. Otherwise referencing
                mechanism would end up in an endless loop, since B also has ref to A
                and to other objects and A would be supposed to be saved in its turn.
     
                This may be improved in the future so as to allow two-way referencing
                wihtout falling into a cycle. However, this might lead to unnecessary
                resource consumption since we don't always imply saving *all related*
                objects (including far bounds) when we mean to save just the root one
                and its closest/inherent relatives.
     
     
        specificKeys : [String]
     
                - array of chosen keys to save of the object. When set to nil, all keys
                and references are saved as provided with mapping variables. This array
                may contain either property or reference keys or all at the same time.
     
     
        submitBlock : closure
                
                - closure which should be executed prior to submitting CKRecord to
                CloudKit. This one is used internally and currently only used by
                reference prevention mechanism. It is not being exposed to be used
                (nor meant to, at this point) from client-side.
     
     
        updateLastSyncDate : Bool
                
                - used internally by syncEntities function. Tells to update last sync
                date of CKEntity class. Sync dates stored in UserDefaults by CKFramework
                and are needed for proper run of full sync cycles.
     
     
        completionHandler
     
                 - closure to execute after an object has been saved. This is an internal
                parameter and might be removed in future updates for save handling is
                now managed by delegate.

     */

    

    @discardableResult
    internal func saveRecordSync(entity : CKEntity,
                                 preventReferenceCycle : Bool = false,
                                 specificKeys : [String]? = nil,
                                 submitBlock: ((CKRecord) -> ())? = nil,
                                 updateLastSyncDate: Bool = false,
                                 completionHandler: ((CKEntity, CKRecord?, Error?) -> ())? = nil) -> CKRecord! {
        
        if !preventReferenceCycle && isSyncLocked {
            syncPending = true
            print("[CK SAVE OPERATION FAILURE] Sync locked. Enable sync in the app to allow syncing")
            return nil
        }
        
        guard
            self.container != nil,
            self.delegate != nil,
            self.validateSync() == true,
            let kvcEntity = entity as? NSObject,
            let syncIdKey = type(of:entity).securedSyncKey,
            let changeDateKey = type(of:entity).securedChangeDateKey,
            let dispatch_queue = self.queues.first(where: { $0.label == "cloudkitframework.entity.queue.\((type(of:entity).self).recordType)" }),
            self.delegate.entityDidSaveToCloudCallback != nil
            
            else {
                if self.debugMode { print("[CK SAVE OPERATION FAILURE] Entity \(NSStringFromClass(type(of:entity))) and/or CKController has not been properly initialized!") }
                return nil
        }
        
        let updatedChangeDate = Date()
        
        let syncId = kvcEntity.value(forKey: syncIdKey) as? String ?? ""
        
        if self.ignoreKeys.contains(syncId) {
            if self.debugMode { print("[CK OPERATION] Ignored entity from syncID exception list...") }
            return nil
        }
        
        var existingRecord: CKRecord!
        let mainSemaphore = DispatchSemaphore(value: 0)
        
        dispatch_queue.async(flags: .barrier, execute: { [unowned self] in
            
            // Sub-func, used as starting point: checks if there's already an object over at CK.
            // If it's there, grabs its reference and performs save operation.
            func checkRecord() {
                
                if syncId != "" {
                    
                    let sema = DispatchSemaphore(value: 0)
                    
                    let recordId = CKRecordID.init(recordName: syncId)
                    let operation = CKFetchRecordsOperation.init(recordIDs: [recordId])
                    
                    operation.queuePriority = .high
                    operation.qualityOfService = .userInitiated
                    operation.perRecordCompletionBlock = { record, recordId, error in
                        existingRecord = record
                        
                        // Successfully fetched record
                        if existingRecord != nil {
                            saveRecord(record!)
                        }
                        else {
                            existingRecord = CKRecord.init(recordType: type(of:entity).recordType)
                            saveRecord(existingRecord!)
                        }
                        
                        sema.signal()
                        
                    }
                    self.database.add(operation)
                    
                    _ = sema.wait(timeout: DispatchTime.distantFuture)
                    
                } else {
                    existingRecord = CKRecord.init(recordType: type(of:entity).recordType)
                    saveRecord(existingRecord)
                }
                
                mainSemaphore.signal()
            }
            
            
            func saveRecord(_ record: CKRecord) {
                
                /* Properties */
                for (sourceKey, recordKey) in type(of:entity).mappingDictionary where specificKeys?.contains(sourceKey) ?? true {
                    record[recordKey] = kvcEntity.value(forKeyPath:sourceKey) as? CKRecordValue
                }
                
                record[changeDateKey] = updatedChangeDate as CKRecordValue?
                
                /* Optional/client-specific closure to execute before passing data over to CK/iCloud */
                submitBlock?(record)
                
                /* Single References */
                if !preventReferenceCycle, let refs = type(of:entity).references {
                    for (localKey, referenceKey) in refs where specificKeys?.contains(localKey) ?? true {
                        if let referenceObject = kvcEntity.value(forKey: localKey) as? CKEntity {
                            if let referenceRecord = self.saveRecordSync(entity: referenceObject, preventReferenceCycle: true, submitBlock:
                                { underlyingRecord in
                                    if type(of:referenceObject).isWeak ?? false {
                                        underlyingRecord[type(of:entity).recordType.lowercased()] = CKReference.init(record: record, action: .deleteSelf)
                                    }
                                })
                            {
                                record[referenceKey] = CKReference.init(record: referenceRecord, action: .none)
                            }
                        }
                    }
                }
                
                /* Reference lists */
                if !preventReferenceCycle, let refLists = type(of:entity).referenceLists {
                    for (refListLocalKey, refListRemoteKey) in refLists.map({($0.localSource, $0.remoteKey)}) {
                        
                        let currentReferenceListKey = refListRemoteKey
                        var currentReferrenceArray = [CKReference]()
                        
                        if let refCollection = kvcEntity.value(forKey: refListLocalKey!) as? Array<CKEntity> {
                            for referenceCollectionObject in refCollection {
                                                                
                                if let referenceRecord = self.saveRecordSync(
                                    entity: referenceCollectionObject,
                                    preventReferenceCycle: true,
                                    submitBlock:
                                    { underlyingRecord in
                                        if type(of:referenceCollectionObject).isWeak ?? false {
                                            underlyingRecord[type(of:entity).recordType.lowercased()] = CKReference.init(record: record, action: .deleteSelf)
                                        }
                                    })
                                {
                                    currentReferrenceArray.append(CKReference.init(record: referenceRecord, action: .none))
                                }
                            }
                            
                            record[currentReferenceListKey!] = currentReferrenceArray as CKRecordValue?
                            
                        }
                    }
                }
                
                let sema = DispatchSemaphore(value: 0)
                let operation = CKModifyRecordsOperation.init(recordsToSave: [record], recordIDsToDelete: nil)
                
                operation.queuePriority = .high
                operation.qualityOfService = .userInitiated
                operation.perRecordCompletionBlock = { record, error in
                    DispatchQueue.main.async {
                        if error == nil {
                            kvcEntity.setValue(record.recordID.recordName, forKeyPath: syncIdKey)
                            kvcEntity.setValue(updatedChangeDate, forKeyPath: changeDateKey)
                        }
                        
                        print(error != nil ? "[CK SAVE OPERATION] Error saving \(kvcEntity.className) to iCloud: \(String(describing: error))" : "[CK SAVE OPERATION] \(kvcEntity.className) saved to iCloud")
                        
                        completionHandler?(entity, record, error) ?? self.delegate.entityDidSaveToCloudCallback?(entity: entity, record: record, error: error)
                    
                        if updateLastSyncDate {
                            
                            let T = type(of:entity)
                            
                            UserDefaults.standard.set(Date(), forKey: T.lastSyncKey)
                            UserDefaults.standard.synchronize()
                        }
                    }
                    
                    sema.signal()
                }
                
                operation.completionBlock = {
                    sema.signal()
                }
                self.database.add(operation)
                
                _ = sema.wait(timeout: .distantFuture)
                
            }
            
            checkRecord()
            
        })
        
        _ = mainSemaphore.wait(timeout: .distantFuture)
        
        return existingRecord
    }

    
    // Async wrapper
    internal func saveRecordAsync(entity : CKEntity, updateLastSyncDate: Bool = false, submitBlock: ((CKRecord) -> ())? = nil) {
        DispatchQueue.global(qos: .utility).async { [unowned self] in _ =
            self.saveRecordSync(entity: entity, submitBlock: submitBlock, updateLastSyncDate: updateLastSyncDate)
        }
    }
    
    
    
    
    // MARK: - CORE (PRIVATE) - Sync Entities
    
    
    /*
     
     func syncEntities(...)
     
        Function that runs full sync cycle.
     
     
     Parameters:
     
    
        Barring forcedSync, none of the parameters are used in current design, since
        delegate now provides call-back functionality. Left intact for future prospect.
     
     
     */

    
    
    internal func syncEntities<T>(allEntitiesOfType allEntities: Array<T>?,
                      fetchItemBySyncId : @escaping (T.Type, _ syncId: String)->T? = { _,_ in nil },
                      createItem : @escaping ()->T? = { nil },
                      forcedSync : Bool = false)
                        where T: CKEntity, T: NSObjectProtocol
    {
        if isSyncLocked {
            print("[CK SYNC FAILURE] Sync locked. Enable sync in the app to allow syncing")
            return
        }
        
        guard
            self.container != nil,
            self.delegate != nil,
            self.validateSync() == true,
            let syncIdKey = self.syncIdKey ?? T.self.syncIdKey,
            let changeDateKey = self.changeDateKey ?? T.self.changeDateKey
            else {
                if self.debugMode { print("[CK SYNC] OPERATION FAILURE: Entity \(NSStringFromClass(T.self)) and/or CKController has not been properly initialized!") }
                return
        }
        
        
        var entitiesToCreate = [CKRecord]()
        var entitiesToUpdate = [CKRecord]()
        
        let lastSyncDate : Date! = forcedSync ? Date.distantPast : UserDefaults.standard.object(forKey: T.lastSyncKey) as? Date ?? Date.distantPast
        
        var localEntities = (allEntities ?? (delegate.allEntities(ofType: T.self)! as! [T]))
        
        if !forcedSync {
            localEntities = localEntities
                .filter({
                    
                    let entityChangeDate = ($0 as! NSObject).value(forKey: changeDateKey) as? Date ?? Date()
                    let entitySyncId = ($0 as! NSObject).value(forKey: syncIdKey) as? String ?? ""
                    
                    //  print("Entity Type: \(String(describing: T.self)) | Sync ID: \(entitySyncId)")
                    
                    return (entityChangeDate > lastSyncDate) && (!(self.ignoreKeys ?? []).contains(entitySyncId)) })
                .sorted(by: {
                    func changeDate(of entity: T) -> Date {
                        return (entity as! NSObject).value(forKey: changeDateKey) as? Date ?? Date()
                    }
                    return changeDate(of: $0) > changeDate(of: $1) })
            
        }
        
        
        
        let query = CKQuery.init(recordType: T.recordType, predicate: forcedSync ? NSPredicate.init(value: true) : NSPredicate.init(format: "modificationDate > %@", lastSyncDate as CVarArg))
        let operation = CKQueryOperation.init(query: query)
        
        background_queue.async(execute: {
            operation.queuePriority = .veryHigh
            operation.qualityOfService = .userInitiated
            operation.recordFetchedBlock = { [unowned self] record in
                
                var soughtEntity : T?
                
                DispatchQueue.main.sync {
                    soughtEntity = fetchItemBySyncId(T.self, record.recordID.recordName) ??
                        self.delegate.fetchEntityCallback(ofType: T.self, syncId: record.recordID.recordName) as? T
                }
                
                
                if soughtEntity == nil {
                    entitiesToCreate.append(record)
                    
                    /* if we have found our entity among existing entities) */
                } else {
                    
                    let localDate = (soughtEntity as! NSObject).value(forKey: changeDateKey) as? Date ?? Date.distantPast
                    let remoteDate = record[self.changeDateKey] as? Date ?? Date()
                    
                    let syncState = EntitySyncState(rawValue: localDate.compare(remoteDate).rawValue)
                    
                    if (syncState == .localNewer){
                        self.saveRecordAsync(entity: soughtEntity!)
                    } else if (syncState == .remoteNewer){
                        
                        entitiesToUpdate.append(record)
                        
                    }
                    
                    localEntities = localEntities.filter {
                        return ($0 as! NSObject).value(forKey: T.self.securedSyncKey) as? String ?? "" != record.recordID.recordName
                    }
                }
            }
            
            operation.completionBlock = {
                
                for entity in localEntities {
                    self.saveRecordAsync(entity: entity, updateLastSyncDate: true)
                }
                
                
                self.delegate.syncDidFinish(for:  T.self,
                                            newRecords: entitiesToCreate, updatedRecords: entitiesToUpdate, deletedRecords: [],
                                            finishSync: {
                                                UserDefaults.standard.set(Date(), forKey: T.lastSyncKey)
                                                UserDefaults.standard.synchronize()
                })
                
                if self.debugMode { print("[CK SYNC] Finished sync for entity: \(NSStringFromClass(T.self))") }
                
                
            }
            
            
            self.database.add(operation)
            
        })
        
    }
    
    
    
    
    // MARK: - CORE (PRIVATE) - Fetch references
    
    
    /*
     
     func fetchReferences(...)
     
        Function that fetches references of an entity.
     
        Used internally.
     
     */
    
    
    internal func fetchReferences(_ entity: CKEntity, fromRemote record: CKRecord)  {
        
        guard
            let kvcEntity = entity as? NSObject,
            let dispatch_queue = self.queues.first(where: { $0.label == "cloudkitframework.entity.queue.\((type(of:entity).self).recordType)" })
            else {
                return
        }
        
        let refs = type(of:entity).references
        let refLists = type(of:entity).referenceLists
        
        if refs == nil && refLists == nil { return }
        
        
        let sema = DispatchSemaphore(value: refs != nil ? refs!.count-1 : refLists!.count-1)
        
        
        func setPlaceholderForMissingReference(byKey localKey: String, ofType T: CKEntity.Type) {
            performBlockOnMainThread {
                kvcEntity.setValue( T.referencePlaceholder, forKey: localKey)
                self.delegate.entityDidSaveToCloudCallback!(entity: entity, record: nil, error: nil)
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            dispatch_queue.async(flags: .barrier, execute: {
                
                if let refs = refs {
                    
                    let refSema = DispatchSemaphore(value: refs.count-1)
                    
                    var enumeration = 0
                    
                    for (localKey, referenceKey) in refs {
                        
                        if let className = entity.getTypeOfProperty(name: localKey), let __class = NSClassFromString(className) as? CKEntity.Type {
                            
                            guard let reference = record[referenceKey] as? CKReference else {
                                refSema.signal()
                                setPlaceholderForMissingReference(byKey: localKey, ofType: __class)
                                
                                continue
                            }
                            
                            let operation = CKFetchRecordsOperation.init(recordIDs: [reference.recordID])
                            
                            operation.queuePriority = .high
                            operation.qualityOfService = .userInitiated
                            operation.perRecordCompletionBlock = { record, recordId, error in
                                
                                if error == nil, let record = record {
                                    
                                    DispatchQueue.main.async {
                                        
                                        var refEntity : CKEntity! = self.delegate.fetchEntityCallback(ofType: __class, syncId: record.recordID.recordName)
                                        
                                        if refEntity != nil {
                                            let refEntityChangeDate = (refEntity as! NSObject).value(forKey: __class.securedChangeDateKey!) as? Date ?? Date.distantPast
                                            let remoteChageDate = record[cloudKitInstance.changeDateKey] as? Date ?? Date()
                                            let syncState = EntitySyncState(rawValue: refEntityChangeDate.compare(remoteChageDate).rawValue)
                                            
                                            if syncState == .remoteNewer {
                                                self.updateEntity(refEntity, fromRemote: record)
                                            }
                                            kvcEntity.setValue(refEntity, forKey: localKey)
                                        } else {
                                            
                                            refEntity = self.delegate.createEntityCallback(ofType: __class)
                                            self.updateEntity(refEntity, fromRemote: record)
                                            
                                            kvcEntity.setValue(refEntity, forKey: localKey)
                                        }
                                        
                                        // self.delegate.entityDidSaveToCloudCallback!(entity: entity, record: record, error: error)
                                        self.delegate.syncDidFinish(for: __class, newRecords: [], updatedRecords: [], deletedRecords: [], finishSync: {})
                                        
                                        enumeration += 1
                                        if refs.count == enumeration {
                                            self.delegate.syncDidFinish(for: __class, newRecords: [], updatedRecords: [], deletedRecords: [], finishSync: {})
                                        }
                                    }
                                    
                                    
                                    
                                } else {
                                    setPlaceholderForMissingReference(byKey: localKey, ofType: __class)
                                }
                                
                                sema.signal()
                            }
                            
                            self.database.add(operation)
                        } else {
                            refSema.signal()
                            enumeration += 1
                        }
                        
                    }
                    
                }
                
                
                /* Fetching reference lists */
                if let refLists = refLists {
                    
                    let refSema = DispatchSemaphore(value: refLists.count-1)
                    
                    for (localSource, entityType, referenceListKey) in refLists.map({
                        ($0.localSource, $0.entityType, $0.remoteKey)}) {
                            
                            
                            guard let referenceList = record[referenceListKey!] as? [CKReference] else {
                                refSema.signal()
                                continue
                            }
                            
                            var collectionOfReferenceObjects = Array<AnyObject>()
                            
                            let operation = CKFetchRecordsOperation.init(recordIDs: referenceList.map {$0.recordID})
                            
                            operation.queuePriority = .high
                            operation.qualityOfService = .userInitiated
                            operation.perRecordCompletionBlock = { record, recordId, error in
                                
                                if error == nil, let record = record {
                                    DispatchQueue.main.sync {
                                        
                                        var refEntity : CKEntity! = self.delegate.fetchEntityCallback(ofType: entityType!, syncId: record.recordID.recordName)
                                        
                                        if refEntity != nil {
                                            let refEntityChangeDate = (refEntity as! NSObject).value(forKey: entityType!.securedChangeDateKey!) as? Date ?? Date.distantPast
                                            let remoteChageDate = record[cloudKitInstance.changeDateKey] as? Date ?? Date()
                                            let syncState = EntitySyncState(rawValue: refEntityChangeDate.compare(remoteChageDate).rawValue)
                                            
                                            if syncState == .remoteNewer {
                                                self.updateEntity(refEntity, fromRemote: record)
                                            }
                                            
                                            collectionOfReferenceObjects.append(refEntity)
                                        } else {
                                            
                                            refEntity = self.delegate.createEntityCallback(ofType: entityType!)
                                            self.updateEntity(refEntity, fromRemote: record)
                                        }
                                        
                                        self.delegate.entityDidSaveToCloudCallback!(entity: entity, record: record, error: error)
                                        
                                    }
                                }
                                
                                refSema.signal()
                            }
                            
                            operation.completionBlock = {
                                DispatchQueue.main.async {
                                    kvcEntity.setValue(collectionOfReferenceObjects, forKey: localSource!)
                                }
                            }
                            
                            self.database.add(operation)
                            
                    }
                }
            })
            
        }
    }
    
    
    
// MARK: - PUBLIC - Sync functions
    
    
    /* 
     
     PUBLIC INTERFACE
     
     Functions that are exposed to a user.
     
     
    */

    
    /// Run full sync cycle by calling this function and passing CKEntity class.
    ///
    @objc public func syncEntities(specific : [CKEntity.Type]! = nil, forced: Bool = false) {
        guard
            cloudKitInstance != nil,
            cloudKitInstance.container != nil,
            cloudKitInstance.delegate != nil,
            cloudKitInstance.entities != nil
            else {
                print("[CK SYNC] OPERATION FAILURE: CKController has not been properly initialized!")
                return
        }

        for entity in (specific ?? self.entities) {
            entity.syncEntities(forced: forced)
        }
    }
    
    
    /// func updateEntity(...)
    ///
    /// This function should be called from within syncDidFinish delegate function
    /// to automatically transfer remote values to its respective local fields.
    /// You are free to specify whether or not you want to automatically handle
    /// references by creating respective local objects, which is done by
    /// specifying fetchReferences flag to true. Once set, CKFramework automatically
    /// fetches these objects and assigns them to corresponding root CKEntity fields.
    ///
    
    @objc public func updateEntity(_ entity: CKEntity, fromRemote record: CKRecord, fetchReferences fetch: Bool = false) {
        
        guard
            let kvcEntity = entity as? NSObject,
            let changeDateKey = self.changeDateKey ?? type(of:entity).changeDateKey else { return }
        
        performBlockOnMainThread {
            
            for (localKey, remoteKey) in type(of: entity).mappingDictionary {
                if record[remoteKey] != nil { kvcEntity.setValue(record[remoteKey], forKey: localKey) }
            }
            
            kvcEntity.setValue(record.recordID.recordName, forKey: type(of:entity).securedSyncKey)
            kvcEntity.setValue(record[changeDateKey], forKey: changeDateKey)
            
            self.delegate?.entityDidSaveToCloudCallback?(entity: entity, record: record, error: nil)
            
            if fetch { cloudKitInstance.fetchReferences(entity, fromRemote: record) }
        }
        
    }
    
    
    /// Run full sync cycle by calling this function and passing CKEntity class.
    ///
    @objc public func iCloudSyncEntities(ofType type: CKEntity.Type) {
        type.syncEntities()
    }
    
    @objc public func iCloudForcedSyncEntities(ofType type: CKEntity.Type) {
        type.syncEntities(forced: true)
    }
    
    
    
// MARK: - PUBLIC - Delete functions
    
    @objc public func iCloudDelete(_ entity: CKEntity) {
        
        if isSyncLocked {
            print("[CK SYNC FAILURE] Sync locked. Enable sync in the app to allow syncing")
            
            if let kvcEntity = entity as? NSObject, let syncId = kvcEntity.value(forKey: type(of:entity).securedSyncKey) as? String {
                var deletedList : [String : String]! = UserDefaults.standard.dictionary(forKey: CKDefaults.kDeletedDictionary) as? [String : String] ?? [String:String]()
                deletedList[syncId] = type(of:entity).recordType
                
                UserDefaults.standard.set(deletedList, forKey: CKDefaults.kDeletedDictionary)
                UserDefaults.standard.synchronize()
            }
            

            syncPending = true
            return
        }
        
        if database == nil { return }
        
        guard
            let syncIdKey = type(of: entity).securedSyncKey,
            let syncId = (entity as? NSObject)?.value(forKey: syncIdKey) as? String, syncId != "" else {
            if self.debugMode { print("[CK OPERATION] Unable to delete record without syncID") }
            return
        }

        let recordId = CKRecordID(recordName: syncId)
        
        var operation = CKModifyRecordsOperation.init(recordsToSave: nil, recordIDsToDelete: [recordId])
        
        operation.queuePriority = .veryHigh
        operation.qualityOfService = .userInitiated
        operation.modifyRecordsCompletionBlock = { savedRecords, deletedRecordIDs, error in
            if self.debugMode { print(error != nil ?
                "[CK OPERATION] Couldn't delete record \(String(describing: error))" :
                "[CK OPERATION] Records deleted successfully")
            }
        }
        
        operation.perRecordCompletionBlock = { record, error in
            if error != nil {
                if self.debugMode { print("[CK OPERATION] Couldn't delete record with ID: \(recordId.recordName) \(error!)") }
            } else {
                if self.debugMode { print("[CK OPERATION] Record with ID: \(recordId.recordName) deleted successfully") }
            }
            
        }
        
        database.add(operation)
        
        
        // Compile deletion queue for other devices
        var deleteQueueRecords = [CKRecord]()
        
        for device in self.allDevices where device != self.deviceId {
            let deleteQueueRecordId = CKRecord.init(recordType: CKRecordTypes.deleteQueue)
            deleteQueueRecordId[CKDeleteQueueKeys.deviceId] = device as CKRecordValue?
            deleteQueueRecordId[CKDeleteQueueKeys.recordId] = syncId as CKRecordValue?
            deleteQueueRecordId[CKDeleteQueueKeys.recordType] = type(of:entity).recordType as CKRecordValue?
            
            deleteQueueRecords.append(deleteQueueRecordId)
        }
        
        
        operation = CKModifyRecordsOperation.init(recordsToSave: deleteQueueRecords, recordIDsToDelete: nil)
        operation.queuePriority = .high
        operation.qualityOfService = .userInitiated
        operation.modifyRecordsCompletionBlock = { savedRecords, deletedRecordIDs, error in
            if self.debugMode { print(error == nil ? "[CK OPERATION] Deletion Queue updated successfully" : "[CK OPERATION] Didn't update deletion queue. Possible reason: no other devices are registered. (Error: \(error!)") }
        }
        
        database.add(operation)
        
    }
    
    
    
// MARK: - PUBLIC - Save functions
    
    @objc public func iCloudSaveKeys (_ entity: CKEntity, keys: [String]) {
        DispatchQueue.global().async { [unowned self] in _ =
            self.saveRecordSync(entity: entity, preventReferenceCycle: false, specificKeys: keys, submitBlock: nil, completionHandler: nil)
        }
    }
    
    @objc public func iCloudSaveKeysAndWait (_ entity: CKEntity, keys: [String]) {
        saveRecordSync(entity: entity, preventReferenceCycle: false, specificKeys: keys, submitBlock: nil, completionHandler: nil)
    }
    
    
    @objc public func iCloudSave(_ entity: CKEntity!) {
        saveRecordAsync(entity: entity)
    }
    
    @objc public func iCloudSaveAndWait(_ entity: CKEntity!) {
        saveRecordSync(entity: entity)
    }
    
    
    
// MARK: - PUBLIC - Handle CloudKit Notifications
    
    public func handleCloudKitNotificationWithUserInfo(userInfo : [String: Any]) {
        
        if isSyncLocked {
            print("[CK SYNC] Couldn't handle push notification. Enable sync in the app to allow syncing")
            syncPending = true
            return
        }
        
        
        guard
            cloudKitInstance != nil,
            cloudKitInstance.container != nil,
            cloudKitInstance.delegate != nil
            else {
                print("[CK SYNC] FAILED TO HANDLE PUSH NOTIFICATION: CKFramework has not been properly initialized!")
                return
        }
        
        if let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification {
            
            if notification.queryNotificationReason == .recordDeleted {
                self.processDeleteQueue()
                return
            }
            
            
            let operation = CKFetchRecordsOperation.init(recordIDs: [notification.recordID!])
            
            operation.queuePriority = .high
            operation.qualityOfService = .userInitiated
            operation.perRecordCompletionBlock = { [unowned self] record, recordId, error in
            
                if let record = record {
                    
                    // Item deleted? (recordType == DeleteQueue)
                    if record.recordType == CKRecordTypes.deleteQueue {
                        if record[CKDeleteQueueKeys.deviceId] as? String == self.deviceId,
                            let recordType = record[CKDeleteQueueKeys.recordType] as? String,
                            let T = self.entities.first(where: { $0.recordType == recordType }) {
                        
                            self.delegate.syncDidFinish(for: T.self, newRecords: [], updatedRecords: [], deletedRecords: [CKDeleteInfo.init(entityType: T.self, syncId: record[CKDeleteQueueKeys.recordId] as! String)], finishSync: {
                                self.database.delete(withRecordID: record.recordID, completionHandler: { (record, error) in })
                            })
                            
                        }
                        return
                    }
                    
                    
                    // New or existing item?
                    if let T = self.entities.first(where: { $0.recordType == record.recordType }) {
                        
                        switch notification.queryNotificationReason {
                            
                        case .recordCreated:
                            self.delegate.syncDidFinish(for: T, newRecords: [record], updatedRecords: [], deletedRecords: [], finishSync: {})
                            
                        case .recordUpdated:
                            self.delegate.syncDidFinish(for: T, newRecords: [], updatedRecords: [record], deletedRecords: [], finishSync: {})
                            
                        default: break
                            
                        }
                    }
                }
            }
        }
    }
    
}
