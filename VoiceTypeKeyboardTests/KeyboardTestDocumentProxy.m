#import "KeyboardTestDocumentProxy.h"

@implementation KeyboardTestDocumentProxy {
    NSMutableArray<NSString *> *_insertedTexts;
    NSUInteger _deleteCount;
}

- (instancetype)init {
    if ((self = [super init])) {
        _insertedTexts = [NSMutableArray array];
    }
    return self;
}

- (NSUUID *)documentIdentifier { return self.testDocumentIdentifier; }
- (NSArray<NSString *> *)insertedTexts { return [_insertedTexts copy]; }
- (NSUInteger)deleteCount { return _deleteCount; }
- (NSString *)documentContextBeforeInput { return [_insertedTexts componentsJoinedByString:@""]; }
- (NSString *)documentContextAfterInput { return @""; }
- (NSString *)selectedText { return nil; }
- (UITextInputMode *)documentInputMode { return nil; }
- (BOOL)hasText { return _insertedTexts.count > 0; }
- (void)insertText:(NSString *)text { [_insertedTexts addObject:text]; }
- (void)deleteBackward { _deleteCount += 1; }
- (void)adjustTextPositionByCharacterOffset:(NSInteger)offset {}
- (void)setMarkedText:(NSString *)markedText selectedRange:(NSRange)selectedRange {}
- (void)unmarkText {}
- (UIKeyboardAppearance)keyboardAppearance { return self.testKeyboardAppearance; }
- (UIReturnKeyType)returnKeyType { return UIReturnKeyDefault; }

@end
