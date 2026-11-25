// hermes-touch-id: native biometric validation (Touch ID / Secure Enclave).
//
// Serves as human proof for root actions requested by the agent on tower.
// The broker (root, tower) runs this binary remotely over SSH and trusts
// ONLY the exit code: 0 = fingerprint validated.
//
// The binary lives in the Nix store (root-owned, immutable): the agent, which only has
// marc@mac, cannot replace it with an "exit 0".
//
// Usage: hermes-touch-id "<text displayed in the popup>"
// Output: OK / DENIED / UNAVAILABLE / TIMEOUT on stdout, code 0/1/2/3.

#include <strings.h>
#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *reason = @"Hermes requests a root approval";
        if (argc > 1 && argv[1] != NULL) {
            const char *raw = argv[1];
            if (strncasecmp(raw, "b64:", 4) == 0) {
                NSString *b64 = [NSString stringWithUTF8String:(raw + 4)];
                NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
                if (data) {
                    NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if (decoded.length > 0) reason = decoded;
                }
            } else {
                NSString *given = [NSString stringWithUTF8String:raw];
                if (given.length > 0) reason = given;
            }
        }
        // The popup does not display a free title: we put the maximum useful
        // information in the reason, and bound the length to stay readable.
        if (reason.length > 400) reason = [[reason substringToIndex:400] stringByAppendingString:@"..."];

        LAContext *ctx = [[LAContext alloc] init];
        ctx.localizedFallbackTitle = @"";      // no password fallback
        ctx.localizedCancelTitle = @"Refuse";

        NSError *error = nil;
        if (![ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&error]) {
            printf("UNAVAILABLE %ld %s\n", (long)error.code,
                   error.localizedDescription ? error.localizedDescription.UTF8String : "");
            fflush(stdout);
            return 2;
        }

        __block BOOL finished = NO;
        __block BOOL success = NO;
        [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
            localizedReason:reason
                      reply:^(BOOL ok, NSError *err) {
                          success = ok;
                          finished = YES;
                          if (ok) {
                              printf("OK\n");
                          } else {
                              printf("DENIED %ld %s\n", (long)err.code,
                                     err.localizedDescription ? err.localizedDescription.UTF8String : "");
                          }
                          fflush(stdout);
                      }];

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120.0];
        while (!finished && [deadline timeIntervalSinceNow] > 0.0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        if (!finished) {
            printf("TIMEOUT\n");
            fflush(stdout);
            return 3;
        }
        return success ? 0 : 1;
    }
}
