//
//  BridgingHeader.h
//  CKFramework
//
//  Created by User on 28/01/2017.
//  Copyright © 2017 Academ Media. All rights reserved.
//

#ifndef BridgingHeader_h
#define BridgingHeader_h

NS_INLINE NSException * _Nullable tryBlock(void(^_Nonnull tryBlock)(void)) {
    @try {
        tryBlock();
    }
    @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

#endif /* BridgingHeader_h */
