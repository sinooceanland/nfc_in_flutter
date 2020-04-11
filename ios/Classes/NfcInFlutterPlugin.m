#import <CoreNFC/CoreNFC.h>
#import "NfcInFlutterPlugin.h"

@implementation NfcInFlutterPlugin {
    dispatch_queue_t dispatchQueue;
}
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    dispatch_queue_t dispatchQueue = dispatch_queue_create("me.andisemler.nfc_in_flutter.dispatch_queue", NULL);
    
    FlutterMethodChannel* channel = [FlutterMethodChannel
                                     methodChannelWithName:@"nfc_in_flutter"
                                     binaryMessenger:[registrar messenger]];
    
    FlutterEventChannel* tagChannel = [FlutterEventChannel
                                       eventChannelWithName:@"nfc_in_flutter/tags"
                                       binaryMessenger:[registrar messenger]];
    
    NfcInFlutterPlugin* instance = [[NfcInFlutterPlugin alloc]
                                    init:dispatchQueue
                                    channel:channel];
  
    [registrar addMethodCallDelegate:instance channel:channel];
    [tagChannel setStreamHandler:instance->wrapper];
}
    
- (id)init:(dispatch_queue_t)dispatchQueue channel:(FlutterMethodChannel*)channel {
    self->dispatchQueue = dispatchQueue;
    if (@available(iOS 13.0, *)) {
        wrapper = [[NFCWritableWrapperImpl alloc] init:channel dispatchQueue:dispatchQueue];
    } else if (@available(iOS 11.0, *)) {
        wrapper = [[NFCWrapperImpl alloc] init:channel dispatchQueue:dispatchQueue];
    } else {
        wrapper = [[NFCUnsupportedWrapper alloc] init];
    }
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    dispatch_async(dispatchQueue, ^{
        [self handleMethodCallAsync:call result:result];
    });
}
    
- (void)handleMethodCallAsync:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([@"readNDEFSupported" isEqualToString:call.method]) {
        result([NSNumber numberWithBool:[wrapper isEnabled]]);
    } else if ([@"startNDEFReading" isEqualToString:call.method]) {
        NSDictionary* args = call.arguments;
        [wrapper startReading:[args[@"scan_once"] boolValue] alertMessage:args[@"alert_message"] options:args];
        result(nil);
    } else if ([@"writeNDEF" isEqualToString:call.method]) {
        NSDictionary* args = call.arguments;
        [wrapper writeToTag:args completionHandler:^(FlutterError * _Nullable error) {
            result(error);
        }];
    } else {
        result(FlutterMethodNotImplemented);
    }
}

@end


@implementation NFCWrapperBase

- (void)readerSession:(nonnull NFCNDEFReaderSession *)session didInvalidateWithError:(nonnull NSError *)error API_AVAILABLE(ios(11.0)) {
    // When a session has been invalidated it needs to be created again to work.
    // Since this function is called when it invalidates, the session can safely be removed.
    // A new session doesn't have to be created immediately as that will happen the next time
    // startReading() is called.
    session = nil;
    
    // If the event stream is closed we can't send the error
    if (events == nil) {
        return;
    }
    switch ([error code]) {
        case NFCReaderSessionInvalidationErrorFirstNDEFTagRead:
            // When this error is returned it doesn't need to be sent to the client
            // as it cancels the stream after 1 read anyways
            events(FlutterEndOfEventStream);
            return;
        case NFCReaderErrorUnsupportedFeature:
            events([FlutterError
                    errorWithCode:@"NDEFUnsupportedFeatureError"
                    message:error.localizedDescription
                    details:nil]);
            break;
        case NFCReaderSessionInvalidationErrorUserCanceled:
            events([FlutterError
                    errorWithCode:@"UserCanceledSessionError"
                    message:error.localizedDescription
                    details:nil]);
            break;
        case NFCReaderSessionInvalidationErrorSessionTimeout:
            events([FlutterError
                    errorWithCode:@"SessionTimeoutError"
                    message:error.localizedDescription
                    details:nil]);
            break;
        case NFCReaderSessionInvalidationErrorSessionTerminatedUnexpectedly:
            events([FlutterError
                    errorWithCode:@"SessionTerminatedUnexpectedlyError"
                    message:error.localizedDescription
                    details:nil]);
            break;
        case NFCReaderSessionInvalidationErrorSystemIsBusy:
            events([FlutterError
                    errorWithCode:@"SystemIsBusyError"
                    message:error.localizedDescription
                    details:nil]);
            break;
        default:
            events([FlutterError
                    errorWithCode:@"SessionError"
                    message:error.localizedDescription
                    details:nil]);
    }
    // Make sure to close the stream, otherwise bad things will happen.
    // (onCancelWithArguments will never be called so the stream will
    //  not be reset and will be stuck in a 'User Canceled' error loop)
    events(FlutterEndOfEventStream);
    return;
}

- (FlutterError * _Nullable)onListenWithArguments:(id _Nullable)arguments eventSink:(nonnull FlutterEventSink)events {
    self->events = events;
    return nil;
}

// onCancelWithArguments is called when the event stream is canceled,
// which most likely happens because of manuallyStopStream().
// However if it was not triggered by manuallyStopStream(), it should invalidate
// the reader session if activate
- (FlutterError * _Nullable)onCancelWithArguments:(id _Nullable)arguments {
    if (session != nil) {
        if ([session isReady]) {
            [session invalidateSession];
        }
        session = nil;
    }
    events = nil;
    return nil;
}

// formatMessageWithIdentifier turns a NFCNDEFMessage into a NSDictionary that
// is ready to be sent to Flutter
- (NSDictionary * _Nonnull)formatMessageWithIdentifier:(NSString* _Nonnull)identifier message:(NFCNDEFMessage* _Nonnull)message {
    NSMutableArray<NSDictionary*>* records = [[NSMutableArray alloc] initWithCapacity:message.records.count];
    for (NFCNDEFPayload* payload in message.records) {
        NSString* type;
        type = [[NSString alloc]
                initWithData:payload.type
                encoding:NSUTF8StringEncoding];
        
        NSString* payloadData;
        NSString* data;
        NSString* languageCode;
        if ([@"T" isEqualToString:type]) {
            // Remove the first byte from the payload
            payloadData = [[NSString alloc]
                    initWithData:[payload.payload
                                  subdataWithRange:NSMakeRange(1, payload.payload.length-1)]
                    encoding:NSUTF8StringEncoding];
            
            const unsigned char* bytes = [payload.payload bytes];
            int languageCodeLength = bytes[0] & 0x3f;
            languageCode = [[NSString alloc]
                            initWithData:[payload.payload
                                          subdataWithRange:NSMakeRange(1, languageCodeLength)]
                            encoding:NSUTF8StringEncoding];
            // Exclude the language code from the data
            data = [[NSString alloc]
                   initWithData:[payload.payload
                                 subdataWithRange:NSMakeRange(languageCodeLength+1, payload.payload.length-languageCodeLength-1)]
                   encoding:NSUTF8StringEncoding];
        } else if ([@"U" isEqualToString:type]) {
            NSString* url;
            const unsigned char* bytes = [payload.payload bytes];
            int prefixByte = bytes[0];
            switch (prefixByte) {
                case 0x01:
                    url = @"http://www.";
                    break;
                case 0x02:
                    url = @"https://www.";
                    break;
                case 0x03:
                    url = @"http://";
                    break;
                case 0x04:
                    url = @"https://";
                    break;
                case 0x05:
                    url = @"tel:";
                    break;
                case 0x06:
                    url = @"mailto:";
                    break;
                case 0x07:
                    url = @"ftp://anonymous:anonymous@";
                    break;
                case 0x08:
                    url = @"ftp://ftp.";
                    break;
                case 0x09:
                    url = @"ftps://";
                    break;
                case 0x0A:
                    url = @"sftp://";
                    break;
                case 0x0B:
                    url = @"smb://";
                    break;
                case 0x0C:
                    url = @"nfs://";
                    break;
                case 0x0D:
                    url = @"ftp://";
                    break;
                case 0x0E:
                    url = @"dav://";
                    break;
                case 0x0F:
                    url = @"news:";
                    break;
                case 0x10:
                    url = @"telnet://";
                    break;
                case 0x11:
                    url = @"imap:";
                    break;
                case 0x12:
                    url = @"rtsp://";
                    break;
                case 0x13:
                    url = @"urn:";
                    break;
                case 0x14:
                    url = @"pop:";
                    break;
                case 0x15:
                    url = @"sip:";
                    break;
                case 0x16:
                    url = @"sips";
                    break;
                case 0x17:
                    url = @"tftp:";
                    break;
                case 0x18:
                    url = @"btspp://";
                    break;
                case 0x19:
                    url = @"btl2cap://";
                    break;
                case 0x1A:
                    url = @"btgoep://";
                    break;
                case 0x1B:
                    url = @"btgoep://";
                    break;
                case 0x1C:
                    url = @"irdaobex://";
                    break;
                case 0x1D:
                    url = @"file://";
                    break;
                case 0x1E:
                    url = @"urn:epc:id:";
                    break;
                case 0x1F:
                    url = @"urn:epc:tag:";
                    break;
                case 0x20:
                    url = @"urn:epc:pat:";
                    break;
                case 0x21:
                    url = @"urn:epc:raw:";
                    break;
                case 0x22:
                    url = @"urn:epc:";
                    break;
                case 0x23:
                    url = @"urn:nfc:";
                    break;
                default:
                    url = @"";
            }
            // Remove the first byte from and add the URL prefix to the payload
            NSString* trimmedPayload = [[NSString alloc] initWithData:
                                        [payload.payload subdataWithRange:NSMakeRange(1, payload.payload.length-1)] encoding:NSUTF8StringEncoding];
            NSMutableString* payloadString = [[NSMutableString alloc]
                                              initWithString:trimmedPayload];
            [payloadString insertString:url atIndex:0];
            payloadData = payloadString;
            // Remove the prefix from the payload
            data = [[NSString alloc]
                    initWithData:[payload.payload
                                  subdataWithRange:NSMakeRange(1, payload.payload.length-1)]
                    encoding:NSUTF8StringEncoding];
        } else {
            payloadData = [[NSString alloc]
                           initWithData:payload.payload
                           encoding:NSUTF8StringEncoding];
            data = payloadData;
        }
        
        NSString* identifier;
        identifier = [[NSString alloc]
                      initWithData:payload.identifier
                      encoding:NSUTF8StringEncoding];
        
        NSString* tnf;
        switch (payload.typeNameFormat) {
            case NFCTypeNameFormatEmpty:
                tnf = @"empty";
                break;
            case NFCTypeNameFormatNFCWellKnown:
                tnf = @"well_known";
                break;
            case NFCTypeNameFormatMedia:
                tnf = @"mime_media";
                break;
            case NFCTypeNameFormatAbsoluteURI:
                tnf = @"absolute_uri";
                break;
            case NFCTypeNameFormatNFCExternal:
                tnf = @"external_type";
                break;
            case NFCTypeNameFormatUnchanged:
                tnf = @"unchanged";
                break;
            default:
                tnf = @"unknown";
        }
        
        NSMutableDictionary* record = [[NSMutableDictionary alloc]
                                       initWithObjectsAndKeys:type, @"type",
                                       payloadData, @"payload",
                                       data, @"data",
                                       identifier, @"id",
                                       tnf, @"tnf", nil];
        if (languageCode != nil) {
            [record setObject:languageCode forKey:@"languageCode"];
        }
        [records addObject:record];
    }
    NSDictionary* result = @{
        @"id": identifier,
        @"message_type": @"ndef",
        @"records": records,
    };
    return result;
}

- (NFCNDEFMessage* _Nonnull)formatNDEFMessageWithDictionary:(NSDictionary* _Nonnull)dictionary API_AVAILABLE(ios(13.0)) {
    NSMutableArray<NFCNDEFPayload*>* ndefRecords = [[NSMutableArray alloc] init];
    
    NSDictionary *message = [dictionary valueForKey:@"message"];
    NSArray<NSDictionary*>* records = [message valueForKey:@"records"];
    for (NSDictionary* record in records) {
        NSString* recordID = [record valueForKey:@"id"];
        NSString* recordType = [record valueForKey:@"type"];
        NSString* recordPayload = [record valueForKey:@"payload"];
        NSString* recordTNF = [record valueForKey:@"tnf"];
        NSString* recordLanguageCode = [record valueForKey:@"languageCode"];
        
        NSData* idData;
        if (recordID) {
            idData = [recordID dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            idData = [NSData data];
        }
        NSData* payloadData;
        if (recordPayload) {
            payloadData = [recordPayload dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            payloadData = [NSData data];
        }
        NSData* typeData;
        if (recordType) {
            typeData = [recordType dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            typeData = [NSData data];
        }
        NFCTypeNameFormat tnfValue;
        
        if ([@"empty" isEqualToString:recordTNF]) {
            // Empty records are not allowed to have a ID, type or payload.
            NFCNDEFPayload* ndefRecord = [[NFCNDEFPayload alloc] initWithFormat:NFCTypeNameFormatEmpty type:[[NSData alloc] init] identifier:[[NSData alloc] init] payload:[[NSData alloc] init]];
            [ndefRecords addObject:ndefRecord];
            continue;
        } else if ([@"well_known" isEqualToString:recordTNF]) {
            if ([@"T" isEqualToString:recordType]) {
                NSLocale* locale = [NSLocale localeWithLocaleIdentifier:recordLanguageCode];
                NFCNDEFPayload* ndefRecord = [NFCNDEFPayload wellKnownTypeTextPayloadWithString:recordPayload locale:locale];
                [ndefRecords addObject:ndefRecord];
                continue;
            } else if ([@"U" isEqualToString:recordType]) {
                NFCNDEFPayload* ndefRecord = [NFCNDEFPayload wellKnownTypeURIPayloadWithString:recordPayload];
                [ndefRecords addObject:ndefRecord];
                continue;
            } else {
                tnfValue = NFCTypeNameFormatNFCWellKnown;
            }
        } else if ([@"mime_media" isEqualToString:recordTNF]) {
            tnfValue = NFCTypeNameFormatMedia;
        } else if ([@"absolute_uri" isEqualToString:recordTNF]) {
            tnfValue = NFCTypeNameFormatAbsoluteURI;
        } else if ([@"external_type" isEqualToString:recordTNF]) {
            tnfValue = NFCTypeNameFormatNFCExternal;
        } else if ([@"unchanged" isEqualToString:recordTNF]) {
            // TODO: Return error, not supposed to change the TNF value
            tnfValue = NFCTypeNameFormatUnchanged;
            continue;
        } else {
            tnfValue = NFCTypeNameFormatUnknown;
            // Unknown records are not allowed to have a type
            typeData = [[NSData alloc] init];
        }
        
        NFCNDEFPayload* ndefRecord = [[NFCNDEFPayload alloc] initWithFormat:tnfValue type:typeData identifier:idData payload:payloadData];
        [ndefRecords addObject:ndefRecord];
    }
    
    return [[NFCNDEFMessage alloc] initWithNDEFRecords:ndefRecords];
}

@end

@implementation NFCWrapperImpl

- (id)init:(FlutterMethodChannel*)methodChannel dispatchQueue:(dispatch_queue_t)dispatchQueue {
    self->methodChannel = methodChannel;
    self->dispatchQueue = dispatchQueue;
    return self;
}
    
- (void)startReading:(BOOL)once alertMessage:(NSString* _Nonnull)alertMessage options:(NSDictionary *)options {
    self->invalidateAfterFirstRead = once;
    self->alertMessage = alertMessage;
    if (session == nil) {
        session = [[NFCNDEFReaderSession alloc]initWithDelegate:self queue:dispatchQueue invalidateAfterFirstRead: once];
        session.alertMessage = alertMessage;
    }
    [self->session beginSession];
}
    
- (BOOL)isEnabled {
    return NFCNDEFReaderSession.readingAvailable;
}
    
- (void)readerSession:(nonnull NFCNDEFReaderSession *)session didDetectNDEFs:(nonnull NSArray<NFCNDEFMessage *> *)messages API_AVAILABLE(ios(11.0)) {
    // Iterate through the messages and send them to Flutter with the following structure:
    // { Map
    //   "message_type": "ndef",
    //   "records": [ List
    //     { Map
    //       "type": "The record's content type",
    //       "payload": "The record's payload",
    //       "id": "The record's identifier",
    //     }
    //   ]
    // }
    for (NFCNDEFMessage* message in messages) {
        NSDictionary* result = [self formatMessageWithIdentifier:@"" message:message];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->events != nil) {
               self->events(result);
            }
        });
    }
}

- (void)readerSession:(NFCNDEFReaderSession *)session
        didDetectTags:(NSArray<__kindof id<NFCNDEFTag>> *)tags API_AVAILABLE(ios(13.0)) {
    // Iterate through the tags and send them to Flutter with the following structure:
    // { Map
    //   "id": "", // empty
    //   "message_type": "ndef",
    //   "records": [ List
    //     { Map
    //       "type": "The record's content type",
    //       "payload": "The record's payload",
    //       "id": "The record's identifier",
    //     }
    //   ]
    // }
    
    for (id<NFCNDEFTag> tag in tags) {
        [session connectToTag:tag completionHandler:^(NSError * _Nullable error) {
            if (error != nil) {
                NSLog(@"connect error: %@", error.localizedDescription);
                return;
            }
            [tag readNDEFWithCompletionHandler:^(NFCNDEFMessage * _Nullable message, NSError * _Nullable error) {
                
                if (error != nil) {
                    NSLog(@"ERROR: %@", error.localizedDescription);
                    return;
                }
                
                NSDictionary* result = [self formatMessageWithIdentifier:@"" message:message];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self->events != nil) {
                        self->events(result);
                    }
                });
            }];
        }];
    }
}

- (void)readerSessionDidBecomeActive:(NFCNDEFReaderSession *)session API_AVAILABLE(ios(13.0)) {}

- (void)writeToTag:(NSDictionary*)data completionHandler:(void (^_Nonnull) (FlutterError * _Nullable error))completionHandler {
    completionHandler(nil);
}

@end

@interface NFCWritableWrapperImpl ()
{
    BOOL _tagReadFinish;
    BOOL _enableTagReader;
    BOOL _onlyEnableTagReader;
}

@end

@implementation NFCWritableWrapperImpl

@synthesize lastTag;

- (void)startReading:(BOOL)once alertMessage:(NSString* _Nonnull)alertMessage options:(NSDictionary *)options {
    self->invalidateAfterFirstRead = once;
    self->alertMessage = alertMessage;
    _enableTagReader = [options[@"enable_tag_reader"] boolValue];
    _onlyEnableTagReader = [options[@"only_enable_tag_reader"] boolValue];
    if (_enableTagReader || _onlyEnableTagReader) {
        [self startReadingTag];
    } else {
        [self startReadingNDEF];
    }
}

- (void)startReadingTag {
    if (self.tagSession == nil) {
        self.tagSession = [[NFCTagReaderSession alloc] initWithPollingOption:(NFCPollingISO14443 | NFCPollingISO15693 | NFCPollingISO15693) delegate:self queue:dispatchQueue];
        self.tagSession.alertMessage = self->alertMessage;
    }
    [self.tagSession beginSession];
}

- (void)startReadingNDEF {
    if (session == nil) {
        session = [[NFCNDEFReaderSession alloc]initWithDelegate:self queue:dispatchQueue invalidateAfterFirstRead: self->invalidateAfterFirstRead];
        session.alertMessage = self->alertMessage;
    }
    [self->session beginSession];
}

- (void)tagReaderSessionDidBecomeActive:(NFCTagReaderSession *)session {}

- (void)tagReaderSession:(NFCTagReaderSession *)session didInvalidateWithError:(NSError *)error {
    // When a session has been invalidated it needs to be created again to work.
    // Since this function is called when it invalidates, the session can safely be removed.
    // A new session doesn't have to be created immediately as that will happen the next time
    // startReading() is called.
    self.tagSession = nil;
    
    // If the event stream is closed we can't send the error
    if (events == nil) {
        return;
    }
    switch ([error code]) {
        case NFCReaderSessionInvalidationErrorFirstNDEFTagRead:
            // When this error is returned it doesn't need to be sent to the client
            // as it cancels the stream after 1 read anyways
            events(FlutterEndOfEventStream);
            return;
        case NFCReaderErrorUnsupportedFeature:
            events([FlutterError
                    errorWithCode:@"NDEFUnsupportedFeatureError"
                    message:error.localizedDescription
                    details:nil]);
            break;
        case NFCReaderSessionInvalidationErrorUserCanceled:
            if (_tagReadFinish) {
                _tagReadFinish = NO;
                return;
            }
            events([FlutterError
                    errorWithCode:@"UserCanceledSessionError"
                    message:error.localizedDescription
                    details:nil]);
            break;
        case NFCReaderSessionInvalidationErrorSessionTimeout:
            events([FlutterError
                    errorWithCode:@"SessionTimeoutError"
                    message:error.localizedDescription
                    details:nil]);
            break;
        case NFCReaderSessionInvalidationErrorSessionTerminatedUnexpectedly:
            events([FlutterError
                    errorWithCode:@"SessionTerminatedUnexpectedlyError"
                    message:error.localizedDescription
                    details:nil]);
            break;
        case NFCReaderSessionInvalidationErrorSystemIsBusy:
            events([FlutterError
                    errorWithCode:@"SystemIsBusyError"
                    message:error.localizedDescription
                    details:nil]);
            break;
        default:
            events([FlutterError
                    errorWithCode:@"SessionError"
                    message:error.localizedDescription
                    details:nil]);
    }
    // Make sure to close the stream, otherwise bad things will happen.
    // (onCancelWithArguments will never be called so the stream will
    //  not be reset and will be stuck in a 'User Canceled' error loop)
    events(FlutterEndOfEventStream);
    return;
}

- (void)tagReaderSession:(NFCTagReaderSession *)session didDetectTags:(NSArray<__kindof id<NFCTag>> *)tags {
    NSLog(@"%@",tags);
    self.cuurentTag = [tags firstObject];
    id<NFCMiFareTag> mifareTag = [self.cuurentTag asNFCMiFareTag];
    NSData *data = mifareTag.identifier;
    NSString *hexStr = [self convertDataBytesToHex:data];
    NSString *numStr = [self getNumberWithHex:hexStr];
    //NSLog(@"result---%@",numStr);
    self->tagIdentifier = hexStr;
    NSDictionary* result = @{
        @"id": @"",
        @"message_type": @"tag",
        @"type": @"tag",
        @"tagId": self->tagIdentifier ?: @"",
    };
    if (self->events != nil) {
        self->events(result);
    }
    
    // stop reading tag，begin reading NDEF
    _tagReadFinish = YES;
    [self.tagSession invalidateSession];
    if (!_onlyEnableTagReader) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self startReadingNDEF];
        });
    }
}

- (NSString *)convertDataBytesToHex:(NSData *)dataBytes {
    if (!dataBytes || [dataBytes length] == 0) {
        return @"";
    }
    NSMutableString *hexStr = [[NSMutableString alloc] initWithCapacity:[dataBytes length]];
    [dataBytes enumerateByteRangesUsingBlock:^(const void *bytes, NSRange byteRange, BOOL *stop) {
        unsigned char *dataBytes = (unsigned char *)bytes;
        for (NSInteger i = 0; i < byteRange.length; i ++) {
            NSString *singleHexStr = [NSString stringWithFormat:@"%x", (dataBytes[i]) & 0xff];
            if ([singleHexStr length] == 2) {
                [hexStr appendString:singleHexStr];
            } else {
                [hexStr appendFormat:@"0%@", singleHexStr];
            }
        }
    }];
    return hexStr;
}


/// 从 16 进制字符串中拼出一个8位数“卡号”
/// @param hexStr 16 进制字符串
/// 16 进制字符串需要至少包含 3 个字节
/**
 * 04 c8 cd d2 d2 64 80
 * 卡号这么取：取前三个字节进行处理，高低位按照 [低位][高位] 的顺序处理
 * cd转10进制，不足三位补零，得205
 * c804拼起来转10进制，不足五位补零，得51204
 * 然后两者拼接起来，最终卡号20551204
 */
- (NSString *)getNumberWithHex:(NSString *)hexStr {
    if ([hexStr.lowercaseString hasPrefix:@"0x"]) {
        hexStr = [hexStr substringFromIndex:2];
    }
    if ([hexStr length] < 6) {
        return hexStr;
    }
    
    NSString *byte3 = [hexStr substringWithRange:NSMakeRange(4, 2)]; //低位（第3个字节）
    NSString *byte2 = [hexStr substringWithRange:NSMakeRange(2, 2)]; //高位（第2个字节）
    NSString *byte1 = [hexStr substringWithRange:NSMakeRange(0, 2)]; //低位（第1个字节）
    NSString *tempStr1 = [NSString stringWithFormat:@"%3lu",strtoul([byte3 UTF8String],0,16)]; // 3位数字，不足前置补零
    NSString *tempStr2 = [NSString stringWithFormat:@"%5lu",strtoul([[byte2 stringByAppendingString:byte1] UTF8String],0,16)]; // 5位数字，不足前置补零
    NSString *tempStr = [tempStr1 stringByAppendingString:tempStr2];
    
    return tempStr;
}

- (void)readerSession:(NFCNDEFReaderSession *)session
        didDetectTags:(NSArray<__kindof id<NFCNDEFTag>> *)tags API_AVAILABLE(ios(13.0)) {
    [super readerSession:session didDetectTags:tags];
    
    // Set the last tags scanned
    lastTag = tags[[tags count] - 1];
}

- (void)writeToTag:(NSDictionary*)data completionHandler:(void (^_Nonnull) (FlutterError * _Nullable error))completionHandler {
    NFCNDEFMessage* ndefMessage = [self formatNDEFMessageWithDictionary:data];
    
    if (lastTag != nil) {
        if (!lastTag.available) {
            completionHandler([FlutterError errorWithCode:@"NFCTagUnavailable" message:@"the tag is unavailable for writing" details:nil]);
            return;
        }
        
        // Connect to the tag.
        // The tag might already be connected to, but it doesn't hurt to do it again.
        [session connectToTag:lastTag completionHandler:^(NSError * _Nullable error) {
            if (error != nil) {
                completionHandler([FlutterError errorWithCode:@"IOError" message:[NSString stringWithFormat:@"could not connect to tag: %@", error.localizedDescription] details:nil]);
                return;
            }
            // Get the tag's read/write status
            [self->lastTag queryNDEFStatusWithCompletionHandler:^(NFCNDEFStatus status, NSUInteger capacity, NSError* _Nullable error) {
                
                if (error != nil) {
                    completionHandler([FlutterError errorWithCode:@"NFCUnexpectedError" message:error.localizedDescription details:nil]);
                    return;
                }
                
                // Write to the tag if possible
                if (status == NFCNDEFStatusReadWrite) {
                    [self->lastTag writeNDEF:ndefMessage completionHandler:^(NSError* _Nullable error) {
                        if (error != nil) {
                            FlutterError *flutterError;
                            switch (error.code) {
                                case NFCNdefReaderSessionErrorTagNotWritable:
                                    flutterError = [FlutterError errorWithCode:@"NFCTagNotWritableError" message:@"the tag is not writable" details:nil];
                                    break;
                                case NFCNdefReaderSessionErrorTagSizeTooSmall: {
                                    NSDictionary *details = @{
                                        @"maxSize": [NSNumber numberWithInt:capacity],
                                    };
                                    flutterError = [FlutterError errorWithCode:@"NFCTagSizeTooSmallError" message:@"the tag's memory size is too small" details:details];
                                    break;
                                }
                                case NFCNdefReaderSessionErrorTagUpdateFailure:
                                    flutterError = [FlutterError errorWithCode:@"NFCUpdateTagError" message:@"the reader failed to update the tag" details:nil];
                                    break;
                                default:
                                    flutterError = [FlutterError errorWithCode:@"NFCUnexpectedError" message:error.localizedDescription details:nil];
                            }
                            completionHandler(flutterError);
                        } else {
                            // Successfully wrote data to the tag
                            completionHandler(nil);
                        }
                    }];
                } else {
                    // Writing is not supported on this tag
                    completionHandler([FlutterError errorWithCode:@"NFCTagNotWritableError" message:@"the tag is not writable" details:nil]);
                }
            }];
        }];
    } else {
        completionHandler([FlutterError errorWithCode:@"NFCTagUnavailable" message:@"no tag to write to" details:nil]);
    }
}

@end

@implementation NFCUnsupportedWrapper

- (BOOL)isEnabled {
    // https://knowyourmeme.com/photos/1483348-bugs-bunnys-no
    return NO;
}
- (void)startReading:(BOOL)once alertMessage:(NSString* _Nonnull)alertMessage options:(NSDictionary *)options {
    return;
}

- (FlutterError * _Nullable)onListenWithArguments:(id _Nullable)arguments eventSink:(nonnull FlutterEventSink)events {
    return [FlutterError
            errorWithCode:@"NDEFUnsupportedFeatureError"
            message:nil
            details:nil];
}
    
- (FlutterError * _Nullable)onCancelWithArguments:(id _Nullable)arguments {
    return nil;
}

- (void)writeToTag:(NSDictionary*)data completionHandler:(void (^_Nonnull) (FlutterError * _Nullable error))completionHandler {
    completionHandler([FlutterError
                       errorWithCode:@"NFCWritingUnsupportedFeatureError"
                       message:nil
                       details:nil]);
}
    
@end
