//
//  CHCSVParser.m
//  CHCSVParser
/**
 Copyright (c) 2010 Dave DeLong
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 **/

#import "CHCSVParser.h"

NSString *const CHCSVErrorDomain = @"com.davedelong.csv";

#define CHUNK_SIZE 512
#define DOUBLE_QUOTE '"'
#define COMMA ','
#define OCTOTHORPE '#'
#define BACKSLASH '\\'

@implementation CHCSVParser {
    NSInputStream *_stream;
    NSStringEncoding _streamEncoding;
    NSMutableData *_stringBuffer;
    NSMutableString *_string;
    NSCharacterSet *_validFieldCharacters;
    
    NSInteger _nextIndex;
    
    NSRange _fieldRange;
    NSMutableString *_sanitizedField;
    
    unichar _delimiter;
    
    NSError *_error;
    
    NSUInteger _currentRecord;
    BOOL _cancelled;
}

- (id)initWithCSVString:(NSString *)csv {
    NSStringEncoding encoding = NSUTF8StringEncoding;
    NSInputStream *stream = [NSInputStream inputStreamWithData:[csv dataUsingEncoding:encoding]];
    return [self initWithInputStream:stream usedEncoding:&encoding delimiter:COMMA];
}

- (id)initWithContentsOfCSVFile:(NSString *)csvFilePath {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:csvFilePath];
    NSStringEncoding encoding = NSUTF8StringEncoding;
    return [self initWithInputStream:stream usedEncoding:&encoding delimiter:COMMA];
}

- (id)initWithInputStream:(NSInputStream *)stream usedEncoding:(NSStringEncoding *)encoding delimiter:(unichar)delimiter {
    NSParameterAssert(stream);
    NSParameterAssert(delimiter);
    NSAssert([[NSCharacterSet newlineCharacterSet] characterIsMember:_delimiter] == NO, @"The field delimiter may not be a newline");
    NSAssert(_delimiter != DOUBLE_QUOTE, @"The field delimiter may not be a double quote");
    NSAssert(_delimiter != OCTOTHORPE, @"The field delimiter may not be an octothorpe");
    
    self = [super init];
    if (self) {
        _stream = [stream retain];
        [_stream open];
        
        _stringBuffer = [[NSMutableData alloc] init];
        _string = [[NSMutableString alloc] init];
        
        _delimiter = delimiter;
        
        _nextIndex = 0;
        _recognizesComments = NO;
        _recognizesBackslashesAsEscapes = NO;
        _sanitizesFields = NO;
        _sanitizedField = [[NSMutableString alloc] init];
        
        NSMutableCharacterSet *m = [[NSCharacterSet newlineCharacterSet] mutableCopy];
        NSString *invalid = [NSString stringWithFormat:@"%c%C", DOUBLE_QUOTE, _delimiter];
        [m addCharactersInString:invalid];
        _validFieldCharacters = [[m invertedSet] retain];
        [m release];
        
        if (encoding == NULL || *encoding == 0) {
            // we need to determine the encoding
            [self _sniffEncoding];
            if (encoding) {
                *encoding = _streamEncoding;
            }
        } else {
            _streamEncoding = *encoding;
        }
    }
    return self;
}

- (void)dealloc {
    [_stream close];
    [_stream release];
    [_stringBuffer release];
    [_string release];
    [_sanitizedField release];
    [_validFieldCharacters release];
    [super dealloc];
}

#pragma mark -

- (void)_sniffEncoding {
    uint8_t bytes[CHUNK_SIZE];
    NSUInteger readLength = [_stream read:bytes maxLength:CHUNK_SIZE];
    [_stringBuffer appendBytes:bytes length:readLength];
    
    NSUInteger bufferLength = [_stringBuffer length];
    if (bufferLength > 0) {
        NSStringEncoding encoding = NSUTF8StringEncoding;
        
        UInt8* bytes = (UInt8*)[_stringBuffer bytes];
        if (bufferLength > 3 && bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0xFE && bytes[3] == 0xFF) {
            encoding = NSUTF32BigEndianStringEncoding;
        } else if (bufferLength > 3 && bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0x00 && bytes[3] == 0x00) {
            encoding = NSUTF32LittleEndianStringEncoding;
        } else if (bufferLength > 1 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
            encoding = NSUTF16BigEndianStringEncoding;
        } else if (bufferLength > 1 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
            encoding = NSUTF16LittleEndianStringEncoding;
        } else if (bufferLength > 2 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
            encoding = NSUTF8StringEncoding;
        } else {
            NSString *bufferAsUTF8 = [[NSString alloc] initWithData:_stringBuffer encoding:NSUTF8StringEncoding];
            if (bufferAsUTF8 != nil) {
                encoding = NSUTF8StringEncoding;
                [bufferAsUTF8 release];
            } else {
                NSLog(@"unable to determine stream encoding; assuming MacOSRoman");
                encoding = NSMacOSRomanStringEncoding;
            }
        }
        
        _streamEncoding = encoding;
    }
}

- (void)_loadMoreIfNecessary {
    NSUInteger stringLength = [_string length];
    NSUInteger reloadPortion = stringLength / 3;
    if (reloadPortion < 10) { reloadPortion = 10; }
    
    if ([_stream hasBytesAvailable] && _nextIndex+reloadPortion >= stringLength) {
        // read more
        uint8_t buffer[CHUNK_SIZE];
        NSInteger readBytes = [_stream read:buffer maxLength:CHUNK_SIZE];
        if (readBytes > 0) {
            [_stringBuffer appendBytes:buffer length:readBytes];
            
            NSUInteger readLength = [_stringBuffer length];
            while (readLength > 0) {
                NSString *readString = [[NSString alloc] initWithBytes:[_stringBuffer bytes] length:readLength encoding:_streamEncoding];
                if (readString == nil) {
                    readLength--;
                } else {
                    [_string appendString:readString];
                    [readString release];
                    break;
                }
            };
            
            [_stringBuffer replaceBytesInRange:NSMakeRange(0, readLength) withBytes:NULL length:0];
        }
    }
}

- (void)_advance {
    [self _loadMoreIfNecessary];
    _nextIndex++;
}

- (unichar)_peekCharacter {
    [self _loadMoreIfNecessary];
    if (_nextIndex >= [_string length]) { return '\0'; }
    
    return [_string characterAtIndex:_nextIndex];
}

- (unichar)_peekPeekCharacter {
    [self _loadMoreIfNecessary];
    NSUInteger nextNextIndex = _nextIndex+1;
    if (nextNextIndex >= [_string length]) { return '\0'; }
    
    return [_string characterAtIndex:nextNextIndex];
}

#pragma mark -

- (void)parse {
    [self _beginDocument];
    
    _currentRecord = 0;
    while ([self _parseRecord]) {
        ; // yep;
    }
    
    if (_error != nil) {
        [self _error];
    } else {
        [self _endDocument];
    }
}

- (void)cancelParsing {
    _cancelled = YES;
}

- (BOOL)_parseRecord {
    while ([self _peekCharacter] == OCTOTHORPE) {
        [self _parseComment];
    }
    
    [self _beginRecord];
    while (1) {
        if (![self _parseField]) {
            break;
        }
        if (![self _parseDelimiter]) {
            break;
        }
    }    
    BOOL followedByNewline = [self _parseNewline];
    [self _endRecord];
    
    return (followedByNewline && _error == nil);
}

- (BOOL)_parseNewline {
    if (_cancelled) { return NO; }
    
    NSUInteger charCount = 0;
    while ([[NSCharacterSet newlineCharacterSet] characterIsMember:[self _peekCharacter]]) {
        charCount++;
        [self _advance];
    }
    return (charCount > 0);
}

- (BOOL)_parseComment {
    [self _advance]; // consume the octothorpe
    
    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    
    [self _beginComment];
    BOOL isBackslashEscaped = NO;
    while (1) {
        if (isBackslashEscaped == NO) {
            unichar next = [self _peekCharacter];
            if (next == BACKSLASH && _recognizesBackslashesAsEscapes) {
                isBackslashEscaped = YES;
                [self _advance];
            } else if ([newlines characterIsMember:next] == NO) {
                [self _advance];
            } else {
                // it's a newline
                break;
            }
        } else {
            isBackslashEscaped = YES;
            [self _advance];
        }
    }
    [self _endComment];
    
    return [self _parseNewline];
}

- (BOOL)_parseField {
    if (_cancelled) { return NO; }
    
    [_sanitizedField setString:@""];
    if ([self _peekCharacter] == DOUBLE_QUOTE) {
        return [self _parseEscapedField];
    } else {
        return [self _parseUnescapedField];
    }
}

- (BOOL)_parseEscapedField {
    [self _beginField];
    [self _advance]; // consume the opening double quote
    
    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    BOOL isBackslashEscaped = NO;
    while (1) {
        unichar next = [self _peekCharacter];
        if (next == '\0') { break; }
        
        if (isBackslashEscaped == NO) {
            if (next == BACKSLASH && _recognizesBackslashesAsEscapes) {
                isBackslashEscaped = YES;
                [self _advance]; // consume the backslash
            } else if ([_validFieldCharacters characterIsMember:next] ||
                       [newlines characterIsMember:next] ||
                       next == COMMA) {
                [_sanitizedField appendFormat:@"%C", next];
                [self _advance];
            } else if (next == DOUBLE_QUOTE && [self _peekPeekCharacter] == DOUBLE_QUOTE) {
                [_sanitizedField appendFormat:@"%C", next];
                [self _advance];
                [self _advance];
            } else {
                // not valid, or it's not a doubled double quote
                break;
            }
        } else {
            [_sanitizedField appendFormat:@"%C", next];
            isBackslashEscaped = NO;
            [self _advance];
        }
    }
    
    if ([self _peekCharacter] == DOUBLE_QUOTE) {
        [self _advance];
        [self _endField];
        return YES;
    }
    
    return NO;
}

- (BOOL)_parseUnescapedField {
    [self _beginField];
    
    BOOL isBackslashEscaped = NO;
    while (1) {
        unichar next = [self _peekCharacter];
        if (next == '\0') { break; }
        
        if (isBackslashEscaped == NO) {
            if (next == BACKSLASH && _recognizesBackslashesAsEscapes) {
                isBackslashEscaped = YES;
                [self _advance];
            } else if ([_validFieldCharacters characterIsMember:next]) {
                [_sanitizedField appendFormat:@"%C", next];
                [self _advance];
            } else {
                break;
            }
        } else {
            isBackslashEscaped = NO;
            [_sanitizedField appendFormat:@"%C", next];
            [self _advance];
        }
    }
    
    [self _endField];
    return YES;
}

- (BOOL)_parseDelimiter {
    unichar next = [self _peekCharacter];
    if (next == _delimiter) {
        [self _advance];
        return YES;
    }
    if (next != '\0' && [[NSCharacterSet newlineCharacterSet] characterIsMember:next] == NO) {
        NSString *description = [NSString stringWithFormat:@"Unexpected delimiter. Expected '%C', but got '%C'", _delimiter, [self _peekCharacter]];
        _error = [[NSError alloc] initWithDomain:CHCSVErrorDomain code:CHCSVErrorCodeInvalidFormat userInfo:@{NSLocalizedDescriptionKey : description}];
    }
    return NO;
}

- (void)_beginDocument {
    if ([_delegate respondsToSelector:@selector(parserDidBeginDocument:)]) {
        [_delegate parserDidBeginDocument:self];
    }
}

- (void)_endDocument {
    if ([_delegate respondsToSelector:@selector(parserDidEndDocument:)]) {
        [_delegate parserDidEndDocument:self];
    }
}

- (void)_beginRecord {
    if (_cancelled) { return; }
    
    _currentRecord++;
    if ([_delegate respondsToSelector:@selector(parser:didBeginLine:)]) {
        [_delegate parser:self didBeginLine:_currentRecord];
    }
}

- (void)_endRecord {
    if (_cancelled) { return; }
    
    if ([_delegate respondsToSelector:@selector(parser:didEndLine:)]) {
        [_delegate parser:self didEndLine:_currentRecord];
    }
}

- (void)_beginField {
    if (_cancelled) { return; }
    
    _fieldRange.location = _nextIndex;
}

- (void)_endField {
    if (_cancelled) { return; }
    
    _fieldRange.length = (_nextIndex - _fieldRange.location);
    NSString *field = nil;
    
    if (_sanitizesFields) {
        field = [[_sanitizedField copy] autorelease];
    } else {
        field = [_string substringWithRange:_fieldRange];
    }
    
    if ([_delegate respondsToSelector:@selector(parser:didReadField:)]) {
        [_delegate parser:self didReadField:field];
    }
    
    [_string replaceCharactersInRange:NSMakeRange(0, NSMaxRange(_fieldRange)) withString:@""];
    _nextIndex = 0;
}

- (void)_beginComment {
    if (_cancelled) { return; }
    
    _fieldRange.location = _nextIndex;
}

- (void)_endComment {
    if (_cancelled) { return; }
    
    _fieldRange.length = (_nextIndex - _fieldRange.location);
    if ([_delegate respondsToSelector:@selector(parser:didReadComment:)]) {
        NSString *comment = [_string substringWithRange:_fieldRange];
        [_delegate parser:self didReadComment:comment];
    }
    
    [_string replaceCharactersInRange:NSMakeRange(0, NSMaxRange(_fieldRange)) withString:@""];
    _nextIndex = 0;
}

- (void)_error {
    if (_cancelled) { return; }
    
    if ([_delegate respondsToSelector:@selector(parser:didFailWithError:)]) {
        [_delegate parser:self didFailWithError:_error];
    }
}

@end

@implementation CHCSVWriter {
    NSOutputStream *_stream;
    NSStringEncoding _streamEncoding;
    
    NSData *_delimiter;
    NSData *_bom;
    NSCharacterSet *_illegalCharacters;
    
    NSUInteger _currentField;
}

- (instancetype)initForWritingToCSVFile:(NSString *)path {
    NSOutputStream *stream = [NSOutputStream outputStreamToFileAtPath:path append:NO];
    return [self initWithOutputStream:stream encoding:NSUTF8StringEncoding delimiter:COMMA];
}

- (instancetype)initWithOutputStream:(NSOutputStream *)stream encoding:(NSStringEncoding)encoding delimiter:(unichar)delimiter {
    self = [super init];
    if (self) {
        _stream = [stream retain];
        _streamEncoding = encoding;
        
        if ([_stream streamStatus] == NSStreamStatusNotOpen) {
            [_stream open];
        }
        
        NSData *a = [@"a" dataUsingEncoding:_streamEncoding];
        NSData *aa = [@"aa" dataUsingEncoding:_streamEncoding];
        if ([a length] * 2 != [aa length]) {
            NSUInteger characterLength = [aa length] - [a length];
            _bom = [[a subdataWithRange:NSMakeRange(0, [a length] - characterLength)] retain];
            [self _writeData:_bom];
        }
        
        NSString *delimiterString = [NSString stringWithFormat:@"%C", delimiter];
        NSData *delimiterData = [delimiterString dataUsingEncoding:_streamEncoding];
        if ([_bom length] > 0) {
            _delimiter = [[delimiterData subdataWithRange:NSMakeRange([_bom length], [delimiterData length] - [_bom length])] retain];
        } else {
            _delimiter = [delimiterData retain];
        }
        
        NSMutableCharacterSet *illegalCharacters = [[NSCharacterSet newlineCharacterSet] mutableCopy];
        [illegalCharacters addCharactersInString:delimiterString];
        [illegalCharacters addCharactersInString:@"\""];
        _illegalCharacters = [illegalCharacters copy];
        [illegalCharacters release];
    }
    return self;
}

- (void)dealloc {
    [self closeStream];
    
    [_delimiter release];
    [_bom release];
    [_illegalCharacters release];
    [super dealloc];
}

- (void)_writeData:(NSData *)data {
    const void *bytes = [data bytes];
    [_stream write:bytes maxLength:[data length]];
}

- (void)_writeString:(NSString *)string {
    NSData *stringData = [string dataUsingEncoding:_streamEncoding];
    if ([_bom length] > 0) {
        stringData = [stringData subdataWithRange:NSMakeRange([_bom length], [stringData length] - [_bom length])];
    }
    [self _writeData:stringData];
}

- (void)_writeDelimiter {
    [self _writeData:_delimiter];
}

- (void)writeField:(NSString *)field {
    if (_currentField > 0) {
        [self _writeDelimiter];
    }
    NSString *string = field;
    if ([string rangeOfCharacterFromSet:_illegalCharacters].location != NSNotFound) {
        // replace double quotes with double double quotes
        string = [string stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
        // surround in double quotes
        string = [NSString stringWithFormat:@"\"%@\"", string];
    }
    [self _writeString:string];
    _currentField++;
}

- (void)finishLine {
    [self _writeString:@"\n"];
    _currentField = 0;
}

- (void)_finishLineIfNecessary {
    if (_currentField != 0) {
        [self finishLine];
    }
}

- (void)writeLineOfFields:(NSArray *)fields {
    [self _finishLineIfNecessary];
    
    for (NSString *field in fields) {
        [self writeField:field];
    }
    [self finishLine];
}

- (void)writeComment:(NSString *)comment {
    [self _finishLineIfNecessary];
    
    NSArray *lines = [comment componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *commented = [NSString stringWithFormat:@"#%@\n", line];
        [self _writeString:commented];
    }
}

- (void)closeStream {
    [_stream close];
    [_stream release], _stream = nil;
}

@end

#pragma mark - Convenience Categories

@interface _CHCSVAggregator : NSObject <CHCSVParserDelegate>

@property (readonly) NSArray *lines;
@property (readonly) NSError *error;

@end

@implementation _CHCSVAggregator {
    NSMutableArray *_lines;
    NSMutableArray *_currentLine;
}

- (id)init {
    self = [super init];
    if (self) {
        
    }
    return self;
}

- (void)dealloc {
    [_lines release];
    [_error release];
    [super dealloc];
}

- (void)parserDidBeginDocument:(CHCSVParser *)parser {
    _lines = [[NSMutableArray alloc] init];
}

- (void)parser:(CHCSVParser *)parser didBeginLine:(NSUInteger)recordNumber {
    _currentLine = [[NSMutableArray alloc] init];
}

- (void)parser:(CHCSVParser *)parser didEndLine:(NSUInteger)recordNumber {
    [_lines addObject:_currentLine];
    [_currentLine release], _currentLine = nil;
}

- (void)parser:(CHCSVParser *)parser didReadField:(NSString *)field {
    [_currentLine addObject:field];
}

- (void)parser:(CHCSVParser *)parser didFailWithError:(NSError *)error {
    _error = [error retain];
    [_lines release], _lines = nil;
}

@end

@implementation NSArray (CHCSVAdditions)

+ (instancetype)arrayWithContentsOfCSVFile:(NSString *)csvFilePath {
    NSParameterAssert(csvFilePath);
    _CHCSVAggregator *aggregator = [[_CHCSVAggregator alloc] init];
    CHCSVParser *parser = [[CHCSVParser alloc] initWithContentsOfCSVFile:csvFilePath];
    [parser setDelegate:aggregator];
    [parser parse];
    [parser release];
    
    NSArray *final = [[[aggregator lines] retain] autorelease];
    [aggregator release];
    
    return final;
}

- (NSString *)CSVString {
    NSOutputStream *output = [NSOutputStream outputStreamToMemory];
    CHCSVWriter *writer = [[CHCSVWriter alloc] initWithOutputStream:output encoding:NSUTF8StringEncoding delimiter:COMMA];
    for (id object in self) {
        if ([object conformsToProtocol:@protocol(NSFastEnumeration)]) {
            [writer writeLineOfFields:object];
        }
    }
    [writer closeStream];
    [writer release];
    
    NSData *buffer = [output propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
    NSString *string = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
    return [string autorelease];
}

@end

@implementation NSString (CHCSVAdditions)

- (NSArray *)CSVComponents {
    _CHCSVAggregator *aggregator = [[_CHCSVAggregator alloc] init];
    CHCSVParser *parser = [[CHCSVParser alloc] initWithCSVString:self];
    [parser setDelegate:aggregator];
    [parser parse];
    [parser release];
    
    NSArray *final = [[[aggregator lines] retain] autorelease];
    [aggregator release];
    
    return final;
}

@end