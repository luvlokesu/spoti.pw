// A short looping MP4 built from the track's still cover, so the lock screen keeps playing full
// screen even when no source has a real clip for it. The still is panned slightly and a translucent
// gradient painted from the cover's own palette rotates over it, each loop closing on its first
// frame. Cached in the same directory as the fetched clips: regenerated only on cache miss.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Build (or hit the cache for) the clip. `identifier` scopes the file name — a track URI does.
// `aspect` is width / height, matching what the system takes for the chosen now playing key. `done`
// runs on the main queue with the local file URL, or nil when the build failed.
void SGGeneratedArtworkMake(UIImage *cover, NSString *identifier, CGFloat aspect, void (^done)(NSURL *file, NSString *note));

// Drops the build in flight, same contract as SGArtworkCancelFetch.
void SGGeneratedArtworkCancel(void);
