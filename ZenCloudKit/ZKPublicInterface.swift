/***********************************************************************
 
 ZenCloudKit v.0.1 (beta)
 
 ZenCloudKit is a framework intended to facilitate the use of native
 CloudKit framework, rendering unified interface which could be
 implemented in projects that employ CoreData (though CoreData is not
 a requirement), making it much easier for developer to implement
 basic (as well as more advanced) operations, such as saving, deleting
 and syncing objects to/with CloudKit, including references and push
 notifications management.
 
 Currently is in beta. Some issues are known and pending update.
 
 Programmed by Hexfire (trancing@gmail.com) from 11/2016 to 02/2017.
 
 ***********************************************************************
 
 
 CKInterface.swift
 
 Client-side interfaces (protocols) are defined here.
 
*/

import Cocoa
import CloudKit


/***********************************************************************
 
 ZenCloudKitProtocol
 
 Main protocol which should be implemented by Delegate.
 
 This is required for ZenCloudKit to function.
 
 
 # Sample:
 
 let cloudKit = CloudKitFramework.sharedInstance
 cloudKit.delegate = self
 
 ***********************************************************************
 
 
 INTERFACE
 
 
 * [1] createEntity - function which should return newly
   created entity object of type T. This is required for internal sync
   functionality to work.
 
   TO-DO:
   On client-side, type-check T (is, as), create and return new T object
 
 
 * [2] fetchEntity - function which should return local
   object of type T by the given syncId. If no object could be fetched,
   return nil.
 
   TO-DO:
   On client-side, type-check T (is, as), fetch T object by syncId if any,
   otherwise return nil.
 
 
 * [3] zenAllEntities - function which should return all entities of type T
 
   TO-DO:
   On client-side, type-check T (is, as), fetch and return all T objects (or nil)
 
 
 * [4] zenSyncDidFinish - function which is called everytime T objects finish syncing
 
   TO-DO:
   On client-side, type-check T (is, as). If it's not nil, parse newRecords
   and updatedRecords arrays to create and update local objects. Otherwise,
   check deletedRecords (array of ZKDeleteInfo objects) which contain
   entityType and syncId fields. Use entityType to determine the type of
   deleted ZKEntity object and syncId to fetch particular object. Once parsed,
   make required actions for your app to reflect changes made (e.g. update
   UI and content).

   IMPORTANT: call finishSync() after you have finished with local adjustments
              to synchronize remote database state.

 
 * [5] zenEntityDidSaveToCloud - function which is called once an object
   has been saved to CloudKit database by ZenCloudKit. This one is optional,
   but highly recommended to implement especially if CoreData entities are
   used. ZenCloudKit sets/updates syncID and changeDate properties of your
   local objects, which means database context must be saved.
 
   TO-DO:
   On client-side, perform required UI/app-content-related actions pertaining
   to the newly saved entity object. E.g., NSManagedObjectContext can be saved
   here. NOTE: this callback is called internally from the main queue, so you
   won't need to make this additional call unless any background operations
   are required otherwise.
 
 
*/


@objc public protocol ZenCloudKitProtocol {
    
    @objc func zenCreateEntity(ofType T: ZKEntity.Type) -> ZKEntity?
    @objc func zenFetchEntity(ofType T: ZKEntity.Type, syncId: String) -> ZKEntity?
    @objc func zenAllEntities(ofType T: ZKEntity.Type) -> [ZKEntity]?
    @objc func zenSyncDidFinish(for T: ZKEntity.Type!,
                             newRecords:[CKRecord],
                             updatedRecords:[CKRecord],
                             deletedRecords:[ZKDeleteInfo],
                             finishSync: @escaping ()->())
    
    @objc optional func zenEntityDidSaveToCloud (entity: ZKEntity, record: CKRecord?, error: Error?)
    
}



/***********************************************************************
 
 ZKEntity
 
 Protocol implemented by NSObject-derived entities you would want to
 sync with CloudKit. For instance, NSManagedObject subclass is a fair choice.
 
 NOTE: It is required that your entities derive from NSObject for ZenCloudKit
       to function, since KVC is a foundation of all mapping-related operations.
 
 
 ***********************************************************************
 
 
 INTERFACE
 
 
   All variables are class-level (static).
 
 
        [ REQUIRED ]
          two items are required
 
 
  * [1] recordType - corresponding CloudKit Record Type. This is the first
        step to establish mapping betwen local and remote objects.
 
 
        Usage:
            static var recordType = "MyRecordType"
 
 
 
  * [2] mappingDictionary - dictionary which contains mapped properties.
        The scheme is: [ localKey (local object) : remoteKey (CloudKit) ]
 
 
        Usage:
            static var mappingDictionary = [ "firstName" : "firstName" ]
 
 
 
        [ OPTIONALS ]
          optional and conditionally optional items
 
 
  * [3] syncIdKey - name of the property which holds the ID of remote object.
        This is conditionally optional, since it's suffice to specify syncIdKey
        for all CK Entities while initializing ZenCloudKit instance.
 
    
        Usage:
            static var syncId: String = "cloudKitId"
            
            // cloudKitId is a property of your
            //                   ZKEntity class
 
 
 
  * [4] changeDateKey - name of the property which holds object change date.
        This is not required for it's suffice to specify changeDateKey for all
        entities while initializing ZenCloudKit instance.
 
 
        Usage:
            static var changeDateKey: String = "changeDate"
 
 
 
  * [5] references - dictionary which contains mapped to-one-references to other objects.
        The scheme is: [ localObject : remoteKey ]
        The gist here is that localObject MUST also correctly implement ZKEntity.
        When you call save() method on your local object, ZenCloudKit will attempt
        to save all referenced objects as well by consequently setting references
        over in the CloudKit database (reflected in the CK dashboard).
        Programmatically speaking, it's all about creating CKReference.
 
 
        Usage:
             static var references : [String : String] =
                                        ["homeAddress" : "address"]
 
 
 
  * [6] referenceLists - optional array of ZKRefList objects, which represent to-many relationships.
        The scheme is: ZKRefList(entityType: <ZKEntity.Type>, 
                                localSource: <local property which returns array of ZKEntity objects>,
                                remoteKey: <remote key at CloudKit to hold array of CKReference items>

 
        Usage:
            static var referenceLists: [ZKRefList] = [ZKRefList(entityType: Course.self,
                                                    localSource: "courseReferences",
                                                    remoteKey: "courses")]
 
        courseReferences is a user-defined property which returns array of ZKEntity objects
        you are willing to save and add to reference list of saved root object
 
         var courseReferences : [Course]? {
             get {
                 return self.courses?.allObjects as? [Course]
             }
     
             set {
                 DispatchQueue.main.async {
                     self.mutableSetValue(forKey: "courses").removeAllObjects()
                     self.mutableSetValue(forKey: "courses").addObjects(from: newValue!)
                 }
     
             }
         }
        
        Implementing appropriate setter is also required for your app to be able
        to store objects retrieved from CloudKit. Thus, localSource field of ZKRefList
        is essentially a link to a handler that manages in-out operations.
 
 
 
  * [7] isWeak - optional flag which (when set) determines that any other object that links to
        an instance of this one produces weak reference, meaning that respective CKRecord
        will be deleted cascadingly whenever pointing record gets deleted in its turn.
 
        Say, you have an object A which holds the reference to B.
        Setting B.isWeak=true will result in establishing weak reference to object B,
        meaning that deleting object A would cause object B to be deleted as well.
 
        This is native CloudKit functionality which stems from (and refers to) CKReference
        initializer with .deleteSelf flag set:
 
        CKReference.init(record: <CKRecord>, action: .deleteSelf)
 
        Usage:
            static var isWeak = true
 
 
 
  * [8] referencePlaceholder - if your CoreData (or a mere NSObject) entity instance is expected
        to have particular reference to not be nil, you can specify default value (read: default
        object) which will be set whenever there would be no specific reference set over in the
        CloudKit. When synced, ZenCloudKit will automatically assign that placeholder value to a
        property to avoid nil.
 
        Say, you have an object A with property b of type B, locally and in the CloudKit:
 
            A.b, where b: B
 
        But in your CloudKit database you have this (A) object with null reference to B.
        Normally after sync you would have an object A, whose property b would be nil.
        With placeholder property set, ZenCloudKit will automatically handle this situation
        and perform following assignment: A.b = placeholder, with the latter being an instance
        of B you specify.
 
        Usage:
            static var referencePlaceholder: ZKEntity = B.defaultInstance()

        NOTE: reference placeholder is set in the target, not in the source ZKEntity class.
 
*/


@objc public protocol ZKEntity : NSObjectProtocol  {
    
    @objc static var recordType : String {get}
    @objc static var mappingDictionary: [String : String] {get}
    @objc optional static var syncIdKey: String { get }
    @objc optional static var changeDateKey: String { get }
    @objc optional static var references : [String : String] {get}
    @objc optional static var referenceLists : [ZKRefList] {get}
    @objc optional static var isWeak : Bool { get }
    @objc optional static var referencePlaceholder : ZKEntity { get }
    
}



/***********************************************************************
 
 ZKRefList
 
 Proxy-object which contains basic info required for ZenCloudKit to handle
 'to-many' relationships.
 
 
 INTERFACE
 
 entityType - ZKEntity class.
 
 localSource - name of the property which returns array of <entityType> objects
 
 remoteKey - CKRecord key to save list of CKReference objects.
 
 
 Refer to ZKEntity instructions above.
 
 ***********************************************************************/


@objc public class ZKRefList : NSObject {
    
    public var entityType : ZKEntity.Type?
    public var localSource : String?
    public var remoteKey : String?
    
    public init(entityType: ZKEntity.Type, localSource: String, remoteKey: String) {
        self.entityType = entityType
        self.localSource = localSource
        self.remoteKey = remoteKey
    }
}


/***********************************************************************
 
 ZKDeleteInfo
 
 Proxy-object which contains basic info required for ZenCloudKit to handle
 remotely deleted objects. 
 
 Before finalizing deletion during full sync cycle, ZenCloudKit prepares
 a list of ready-to-be-deleted objects by giving you info about their local
 ZKEntity types and IDs so you could perform a cleanup in your app beforehand.

 NOTE: Once having done the cleanup, it's required that you call finishSync()
 within your zenSyncDidFinish implementation to allow ZenCloudKit delete these 
 objects from CloudKit. This is for the safety and integrity of your app.
 
 
 
 INTERFACE
 
 
 
 entityType - class which implements ZKEntity protocol.
 
 syncId - ID which you should use for removal.
 
 
 Refer to ZKEntity instructions above.
 
 ***********************************************************************/


@objc public class ZKDeleteInfo : NSObject {
    
    public var entityType : ZKEntity.Type!
    public var syncId : String!
    
    init(entityType : ZKEntity.Type, syncId: String) {
        self.entityType = entityType
        self.syncId = syncId
    }
    
}


/***********************************************************************
 
 ZKEntityFunctions
 
 Protocol for iCloud proxy-object, currently only available from Swift
 client code.
 
 Lets you make calls such as:
 
 entity.save()
 entity.saveKeysAndWait(["firstName", "lastName")
 
 This is a syntactic sugar.
 
 COMMON way to perform ZKEntity-related operations is via ZenCloudKit
 singleton instance:
 
     let cloudKit = CloudKitFramework.sharedInstance
     
     cloudKit.iCloudSave(<ZKEntity>)
     cloudKit.iCloudSaveAndWait(<ZKEntity>)
 
     etc...
 

 ***********************************************************************/


@objc public protocol ZKEntityFunctions {
    
    @objc func update(fromRemote record: CKRecord, fetchReferences fetch: Bool)
    @objc func save()
    @objc func saveAndWait()
    @objc func delete()
    @objc func saveKeys(_ keys: [String])
    @objc func saveKeysAndWait(_ keys: [String])
    
}



/***********************************************************************
 
 ZKContainerType
 
 CloudKit Container Type (Scope)
 
 This one is set during ZenCloudKit setup.
 
 Usage:
 
     cloudKit.setup(container: "iCloud.com.myapp",
                       ofType: .private,               // <-------- ZKContainerType
                       syncIdKey: "syncID",
                       changeDateKey: "changeDate",
                       entities: [Person.self, Address.self],
                       ignoreKeys: ["demo", "ignore"],
                       deviceId: "...Some UUID String...")

 
 ***********************************************************************/


@objc public enum ZKContainerType : Int {
    case `private`
    case `public`
}



