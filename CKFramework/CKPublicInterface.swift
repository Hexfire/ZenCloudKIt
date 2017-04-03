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
 
 
 CKInterface.swift
 
 Client-side interfaces (protocols) are defined here.
 
*/

import Cocoa
import CloudKit


/***********************************************************************
 
 CloudKitProtocol
 
 Main protocol which should be implemented by Delegate.
 
 This is required for CKFramework to function.
 
 
 # Sample:
 
 let cloudKit = CloudKitFramework.sharedInstance
 cloudKit.delegate = self
 
 ***********************************************************************
 
 
 INTERFACE
 
 
 * [1] createEntityCallback - function which should return newly
   created entity object of type T. This is required for internal sync
   functionality to work.
 
   TO-DO:
   On client-side, type-check T (is, as), create and return new T object
 
 
 * [2] fetchEntityCallback - function which should return local
   object of type T by the given syncId. If no object could be fetched,
   return nil.
 
   TO-DO:
   On client-side, type-check T (is, as), fetch T object by syncId if any,
   otherwise return nil.
 
 
 * [3] allEntities - function which should return all entities of type T
 
   TO-DO:
   On client-side, type-check T (is, as), fetch and return all T objects (or nil)
 
 
 * [4] syncDidFinish - function which is called everytime T objects finish syncing
 
   TO-DO:
   On client-side, type-check T (is, as). If it's not nil, parse newRecords
   and updatedRecords arrays to create and update local objects. Otherwise,
   check deletedRecords (array of CKDeleteInfo objects) which contain
   entityType and syncId fields. Use entityType to determine the type of
   deleted CKEntity object and syncId to fetch particular object. Once parsed,
   make required actions for your app to reflect changes made (e.g. update
   UI and content).

   IMPORTANT: call finishSync() after you have finished with local adjustments
              to synchronize remote database state.

 
 * [5] entityDidSaveToCloudCallback - function which is called once an object
   has been saved to CloudKit database by CKFramework. This one is optional,
   but highly recommended to implement especially if CoreData entities are
   used. CKFramework sets/updates syncID and changeDate properties of your
   local objects, which means database context must be saved.
 
   TO-DO:
   On client-side, perform required UI/app-content-related actions pertaining
   to the newly saved entity object. E.g., NSManagedObjectContext can be saved
   here. NOTE: this callback is called internally from the main queue, so you
   won't need to make this additional call unless any background operations
   are required otherwise.
 
 
*/


@objc public protocol CloudKitProtocol {
    
    @objc func createEntityCallback(ofType T: CKEntity.Type) -> CKEntity?
    @objc func fetchEntityCallback(ofType T: CKEntity.Type, syncId: String) -> CKEntity?
    @objc func allEntities(ofType T: CKEntity.Type) -> [CKEntity]?
    @objc func syncDidFinish(for T: CKEntity.Type!, newRecords:[CKRecord], updatedRecords:[CKRecord], deletedRecords:[CKDeleteInfo], finishSync: @escaping ()->())
    
    @objc optional func entityDidSaveToCloudCallback (entity: CKEntity, record: CKRecord?, error: Error?)
    
}



/***********************************************************************
 
 CKEntity
 
 Protocol implemented by NSObject-derived entities you would want to
 sync with CloudKit. For instance, NSManagedObject subclass is a fair choice.
 
 NOTE: It is required that your entities derive from NSObject for CKFramework
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
        for all CK Entities while initializing CKFramework instance.
 
    
        Usage:
            static var syncId: String = "cloudKitId"
            
            // cloudKitId is a property of your
            //                   CKEntity class
 
 
 
  * [4] changeDateKey - name of the property which holds object change date.
        This is not required for it's suffice to specify changeDateKey for all
        entities while initializing CKFramework instance.
 
 
        Usage:
            static var changeDateKey: String = "changeDate"
 
 
 
  * [5] references - dictionary which contains mapped to-one-references to other objects.
        The scheme is: [ localObject : remoteKey ]
        The gist here is that localObject MUST also correctly implement CKEntity.
        When you call save() method on your local object, CKFramework will attempt
        to save all referenced objects as well by consequently setting references
        over in the CloudKit database (reflected in the CK dashboard).
        Programmatically speaking, it's all about creating CKReference.
 
 
        Usage:
             static var references : [String : String] =
                                        ["homeAddress" : "address"]
 
 
 
  * [6] referenceLists - optional array of CKRefList objects, which represent to-many relationships.
        The scheme is: CKRefList(entityType: <CKEntity.Type>, 
                                localSource: <local property which returns array of CKEntity objects>,
                                remoteKey: <remote key at CloudKit to hold array of CKReference items>

 
        Usage:
            static var referenceLists: [CKRefList] = [CKRefList(entityType: Course.self,
                                                    localSource: "courseReferences",
                                                    remoteKey: "courses")]
 
        courseReferences is a user-defined property which returns array of CKEntity objects
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
        to store objects retrieved from CloudKit. Thus, localSource field of CKRefList
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
        CloudKit. When synced, CKFramework will automatically assign that placeholder value to a
        property to avoid nil.
 
        Say, you have an object A with property b of type B, locally and in the CloudKit:
 
            A.b, where b: B
 
        But in your CloudKit database you have this (A) object with null reference to B.
        Normally after sync you would have an object A, whose property b would be nil.
        With placeholder property set, CKFramework will automatically handle this situation
        and perform following assignment: A.b = placeholder, with the latter being an instance
        of B you specify.
 
        Usage:
            static var referencePlaceholder: CKEntity = B.defaultInstance()

 
        NOTE: reference placeholder is set in the target, not in the source CKEntity class.
 
*/


@objc public protocol CKEntity  {
    
    @objc static var recordType : String {get}
    @objc static var mappingDictionary: [String : String] {get}
    @objc optional static var syncIdKey: String { get }
    @objc optional static var changeDateKey: String { get }
    @objc optional static var references : [String : String] {get}
    @objc optional static var referenceLists : [CKRefList] {get}
    @objc optional static var isWeak : Bool { get }
    @objc optional static var referencePlaceholder : CKEntity { get }
    
}



/***********************************************************************
 
 CKRefList
 
 Proxy-object which contains basic info required for CKFramework to handle
 'to-many' relationships.
 
 
 INTERFACE
 
 entityType - CKEntity class.
 
 localSource - name of the property which returns array of <entityType> objects
 
 remoteKey - CKRecord key to save list of CKReference objects.
 
 
 Refer to CKEntity instructions above.
 
 ***********************************************************************/


@objc public class CKRefList : NSObject {
    
    public var entityType : CKEntity.Type?
    public var localSource : String?
    public var remoteKey : String?
    
    public init(entityType: CKEntity.Type, localSource: String, remoteKey: String) {
        self.entityType = entityType
        self.localSource = localSource
        self.remoteKey = remoteKey
    }
}


/***********************************************************************
 
 CKDeleteInfo
 
 Proxy-object which contains basic info required for CKFramework to handle
 remotely deleted objects. 
 
 Before finalizing deletion during full sync cycle, CKFramework prepares
 a list of ready-to-be-deleted objects by giving you info about their local
 CKEntity types and IDs so you could perform a cleanup in your app beforehand.

 NOTE: Once having done the cleanup, it's required that you call finishSync()
 within your syncDidFinish implementation to allow CKFramework delete these 
 objects from CloudKit. This is for the safety and integrity of your app.
 
 
 
 INTERFACE
 
 
 
 entityType - class which implements CKEntity protocol.
 
 syncId - ID which you should use for removal.
 
 
 Refer to CKEntity instructions above.
 
 ***********************************************************************/


@objc public class CKDeleteInfo : NSObject {
    
    public var entityType : CKEntity.Type!
    public var syncId : String!
    
    init(entityType : CKEntity.Type, syncId: String) {
        self.entityType = entityType
        self.syncId = syncId
    }
    
}


/***********************************************************************
 
 CKEntityFunctions
 
 Protocol for iCloud proxy-object, currently only available from Swift
 client code.
 
 Lets you make calls such as:
 
 entity.save()
 entity.saveKeysAndWait(["firstName", "lastName")
 
 This is a syntactic sugar.
 
 COMMON way to perform CKEntity-related operations is via CKFramework
 singleton instance:
 
     let cloudKit = CloudKitFramework.sharedInstance
     
     cloudKit.iCloudSave(<CKEntity>)
     cloudKit.iCloudSaveAndWait(<CKEntity>)
 
     etc...
 

 ***********************************************************************/


@objc public protocol CKEntityFunctions {
    
    @objc func update(fromRemote record: CKRecord, fetchReferences fetch: Bool)
    @objc func save()
    @objc func saveAndWait()
    @objc func delete()
    @objc func saveKeys(_ keys: [String])
    @objc func saveKeysAndWait(_ keys: [String])
    
}



/***********************************************************************
 
 CKContainerType
 
 CloudKit Container Type (Scope)
 
 This one is set during CKFramework setup.
 
 Usage:
 
     cloudKit.setup(container: "iCloud.com.myapp",
                       ofType: .private,               // <-------- CKContainerType
                       syncIdKey: "syncID",
                       changeDateKey: "changeDate",
                       entities: [Person.self, Address.self],
                       ignoreKeys: ["demo", "ignore"],
                       deviceId: "...Some UUID String...")

 
 ***********************************************************************/


@objc public enum CKContainerType : Int {
    case `private`
    case `public`
}



