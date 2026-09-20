#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// UIKit can return nil while the host connects or replaces the document proxy,
/// despite UITextDocumentProxy declaring this property nonnull. Preserve nil
/// across the Objective-C/Swift boundary instead of forcing an NSUUID bridge.
FOUNDATION_EXPORT NSUUID * _Nullable VTKeyboardDocumentIdentifier(UIInputViewController *controller);

NS_ASSUME_NONNULL_END
