#import "KeyboardDocumentContext.h"

NSUUID * _Nullable VTKeyboardDocumentIdentifier(UIInputViewController *controller) {
    id<UITextDocumentProxy> proxy = controller.textDocumentProxy;
    return proxy.documentIdentifier;
}
