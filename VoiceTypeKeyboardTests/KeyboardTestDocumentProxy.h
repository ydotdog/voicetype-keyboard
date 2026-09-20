#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Deliberately permits the nil identity seen in the physical iPhone crash.
/// Implementing the getter in Objective-C reproduces UIKit's actual boundary;
/// a Swift UUID-returning mock cannot represent this condition.
@interface KeyboardTestDocumentProxy : NSObject <UITextDocumentProxy>
@property (nullable, nonatomic, copy) NSUUID *testDocumentIdentifier;
@property (nonatomic) UIKeyboardAppearance testKeyboardAppearance;
@property (nonatomic, readonly) NSArray<NSString *> *insertedTexts;
@property (nonatomic, readonly) NSUInteger deleteCount;
@end

NS_ASSUME_NONNULL_END
