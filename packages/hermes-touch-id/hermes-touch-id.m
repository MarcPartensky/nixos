// hermes-touch-id : validation biometrique native (Touch ID / Secure Enclave).
//
// Sert de preuve humaine pour les actions root demandees par l'agent sur tower.
// Le broker (root, tower) execute ce binaire a distance par SSH et ne fait
// confiance QU'AU code de sortie : 0 = empreinte validee.
//
// Le binaire vit dans le store Nix (root-owned, immuable) : l'agent, qui n'a que
// marc@mac, ne peut pas le remplacer par un "exit 0".
//
// Usage : hermes-touch-id "<texte affiche dans le popup>"
// Sortie : OK / DENIED / UNAVAILABLE / TIMEOUT sur stdout, code 0/1/2/3.

#include <strings.h>
#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *reason = @"Hermes demande une approbation root";
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
        // Le popup n'affiche pas de titre libre : on met le maximum d'information
        // utile dans la raison, et on borne la longueur pour rester lisible.
        if (reason.length > 400) reason = [[reason substringToIndex:400] stringByAppendingString:@"..."];

        LAContext *ctx = [[LAContext alloc] init];
        ctx.localizedFallbackTitle = @"";      // pas de repli mot de passe
        ctx.localizedCancelTitle = @"Refuser";

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
