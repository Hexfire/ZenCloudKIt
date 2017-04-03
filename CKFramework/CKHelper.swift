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
 
 
 CKHelper.swift
 
 CKFramework helper class
 
*/

import Foundation
import SystemConfiguration

internal class CKReachability {
    internal class func isConnectedToNetwork() -> Bool {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
        zeroAddress.sin_family = sa_family_t(AF_INET)
        let defaultRouteReachability = withUnsafePointer(to: &zeroAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1, {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            })
            
        }
        var flags = SCNetworkReachabilityFlags()
        if !SCNetworkReachabilityGetFlags(defaultRouteReachability!, &flags) {
            return false
        }
        let isReachable = (flags.rawValue & UInt32(kSCNetworkFlagsReachable)) != 0
        let needsConnection = (flags.rawValue & UInt32(kSCNetworkFlagsConnectionRequired)) != 0
        return (isReachable && !needsConnection)
    }
}

extension NSObject {
    
    internal func performBlockOnMainThread(_ block: @escaping () -> Void){
        if Thread.isMainThread { block(); return }
        
        DispatchQueue.main.async(execute: block);
    }
    
}
