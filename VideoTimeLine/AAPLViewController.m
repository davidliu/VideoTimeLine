/*
 Copyright (C) 2014 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 
  ViewController that implements the VTDecompressionSession, reads samplebuffers from a source asset, decodes those frames using VideoToolbox, and displays the timeline.
  
 */

#import "AAPLViewController.h"
#import "AAPLEAGLLayer.h"
@import AVFoundation;
@import CoreMedia;
@import VideoToolbox;
@import QuartzCore;
@import MobileCoreServices;

@interface AAPLImagePickerController : UIImagePickerController

@end

@implementation AAPLImagePickerController


@end
@interface AAPLViewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIPopoverControllerDelegate>
@property AVAssetReader *assetReader;
@property VTDecompressionSessionRef decompressionSession;
@property dispatch_queue_t backgroundQueue;
@property NSMutableArray *outputFrames;
@property NSMutableArray *presentationTimes;
@property CADisplayLink *displayLink;
@property CFTimeInterval lastCallbackTime;
@property dispatch_semaphore_t bufferSemaphore;
@property UIPopoverController *popover;
@property (weak) IBOutlet UIBarButtonItem *playButton;
@property CGAffineTransform videoPreferredTransform;
//@property APLEAGLView *playerView;
@end

@implementation AAPLViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.backgroundQueue = dispatch_queue_create("com.videotimeline.backgroundqueue", NULL);
    self.outputFrames = [[NSMutableArray alloc] init];
    self.presentationTimes = [[NSMutableArray alloc] init];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
    [self.displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.displayLink setPaused:YES];
    self.lastCallbackTime = 0.0;
    self.bufferSemaphore = dispatch_semaphore_create(0);
    
    
    dispatch_async(self.backgroundQueue, ^{
        NSString* path = [[NSBundle mainBundle] pathForResource:@"sample_iPod" ofType:@"m4v"];
        UISaveVideoAtPathToSavedPhotosAlbum(path, self, @selector(video:didFinishSavingWithError:contextInfo:), nil);
    });
    
}
- (void)video:(NSString *)videoPath didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    if (error != nil) {
        NSLog(@"Error saving video: %@", error);
    }
    else{
        NSLog(@"Video saved successfully.");
    }
}

- (void)readSampleBuffersFromAsset:(AVAsset *)asset{
    NSError *error = nil;
    self.assetReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    
    if (error) {
        NSLog(@"Error creating Asset Reader: %@", [error description]);
    }
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    
    __block AVAssetTrack *videoTrack = (AVAssetTrack *)[videoTracks firstObject];
    [self createDecompressionSessionFromAssetTrack:videoTrack];
    AVAssetReaderTrackOutput *videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:nil];
    
    if ([self.assetReader canAddOutput:videoTrackOutput]) {
        [self.assetReader addOutput:videoTrackOutput];
    }
    
    BOOL didStart = [self.assetReader startReading];
    if (!didStart) {
        goto bail;
    }
    
    while (self.assetReader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sampleBuffer = [videoTrackOutput copyNextSampleBuffer];
        if (sampleBuffer) {
            
            VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
            VTDecodeInfoFlags flagOut;
            VTDecompressionSessionDecodeFrame(_decompressionSession, sampleBuffer, flags, NULL, &flagOut);
            
            CFRelease(sampleBuffer);
            if ([self.presentationTimes count] >= 5) {
                dispatch_semaphore_wait(self.bufferSemaphore, DISPATCH_TIME_FOREVER);
            }
        }
        else if (self.assetReader.status == AVAssetReaderStatusFailed){
            NSLog(@"Asset Reader failed with error: %@", [[self.assetReader error] description]);
        } else if (self.assetReader.status == AVAssetReaderStatusCompleted){
            NSLog(@"Reached the end of the video.");
        }
    }
    
bail:
    ;
}

- (void)createDecompressionSessionFromAssetTrack:(AVAssetTrack *)track{
    NSArray *formatDescriptions = [track formatDescriptions];
    CMVideoFormatDescriptionRef formatDescription = (__bridge CMVideoFormatDescriptionRef)[formatDescriptions firstObject];
    
    self.videoPreferredTransform = track.preferredTransform;
    _decompressionSession = NULL;
    
    VTDecompressionOutputCallbackRecord callBackRecord;
    callBackRecord.decompressionOutputCallback = didDecompress;
    callBackRecord.decompressionOutputRefCon = (__bridge void *)self;
    VTDecompressionSessionCreate(kCFAllocatorDefault, formatDescription, NULL, NULL, &callBackRecord, &_decompressionSession);
}

- (void)moveTimeLine{
    NSMutableArray *layersForRemoval = [NSMutableArray array];
    for (CALayer *layer in [self.view.layer sublayers]) {
        if ([layer isKindOfClass:[AAPLEAGLLayer class]]) {
            CGRect frame = layer.frame;
            CGRect newFrame = CGRectMake(frame.origin.x + 20.0f, frame.origin.y - 20.0f, frame.size.width, frame.size.height);
            [layer setFrame:newFrame];
            CGRect screenBounds = [[UIScreen mainScreen] bounds];
            if (newFrame.origin.x >= (screenBounds.origin.x + screenBounds.size.width) || newFrame.origin.y >= (screenBounds.origin.y + screenBounds.size.height)) {//if layer is off screen we can remove it
                if ([layer isKindOfClass:[AAPLEAGLLayer class]]) {
                    [layersForRemoval addObject:layer];
                }
                
            }
            
            
        }
        
    }
    
    [layersForRemoval makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
    [layersForRemoval removeAllObjects];
}
#pragma mark - VideoToolBox Decompress Frame CallBack
/*
 This callback gets called everytime the decompresssion session decodes a frame
 */
void didDecompress( void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp, CMTime presentationDuration ){
    
    if (status == noErr) {
        if (imageBuffer != NULL) {
            __weak __block AAPLViewController *weakSelf = (__bridge AAPLViewController *)decompressionOutputRefCon;
            NSNumber *framePTS = nil;
            if (CMTIME_IS_VALID(presentationTimeStamp)) {
                framePTS = [NSNumber numberWithDouble:CMTimeGetSeconds(presentationTimeStamp)];
            } else{
                NSLog(@"Not a valid time for image buffer: %@", imageBuffer);
            }
            
            if (framePTS) { //find the correct position for this frame in the output frames array
                @synchronized(weakSelf){
                    id imageBufferObject = (__bridge id)imageBuffer;
                    BOOL shouldStop = NO;
                    NSInteger insertionIndex = [weakSelf.presentationTimes count] -1;
                    while (insertionIndex >= 0 && shouldStop == NO) {
                        NSNumber *aNumber = weakSelf.presentationTimes[insertionIndex];
                        if ([aNumber floatValue] <= [framePTS floatValue]) {
                            shouldStop = YES;
                            break;
                        }
                        insertionIndex--;
                    }
                    if (insertionIndex + 1 == [weakSelf.presentationTimes count]) {
                        [weakSelf.presentationTimes addObject:framePTS];
                        [weakSelf.outputFrames addObject:imageBufferObject];
                    } else{
                        [weakSelf.presentationTimes insertObject:framePTS atIndex:insertionIndex + 1];
                        [weakSelf.outputFrames insertObject:imageBufferObject atIndex:insertionIndex + 1];
                    }
                    
                    
                }
                
                
            }
        }
    } else {
        NSLog(@"Error decompresssing frame at time: %.3f error: %d infoFlags: %u", (float)presentationTimeStamp.value/presentationTimeStamp.timescale, (int)status, (unsigned int)infoFlags);
    }
}

#pragma mark - CADisplayLink Callback

- (void)displayLinkCallback:(CADisplayLink *)sender
{
    /*
     The callback gets called once every Vsync.
     Using the display link's timestamp and duration we can compute the next time the screen will be refreshed, get the imagebuffer from our queue and render it on screen at the right time
     */
    
    // if we haven't had a callback yet, we can set the last call back time to the CADisplayLink time
    if (self.lastCallbackTime == 0.0f) {
        self.lastCallbackTime = [sender timestamp];
    }
    CFTimeInterval timeSinceLastCallback = [sender timestamp] - self.lastCallbackTime;
    
    if ([self.outputFrames count] && [self.presentationTimes count]) {
        
        CVImageBufferRef imageBuffer = NULL;
        NSNumber *framePTS = nil;
        id imageBufferObject = nil;
        @synchronized(self){
            
            framePTS = [self.presentationTimes firstObject];
            imageBufferObject = [self.outputFrames firstObject];
            
            imageBuffer = (__bridge CVImageBufferRef)imageBufferObject;
        }
            //check if the current time is greater than or equal to the presentation time of the sample buffer
            if (timeSinceLastCallback >= [framePTS floatValue] ) {
                
                //draw the imagebuffer, move the time line, and update the queues
                @synchronized(self){
                    if (imageBufferObject) {
                        [self.outputFrames removeObjectAtIndex:0];
                    }
                    
                    if (framePTS) {
                        [self.presentationTimes removeObjectAtIndex:0];
                        
                        if ([self.presentationTimes count] == 3) {
                            dispatch_semaphore_signal(self.bufferSemaphore);
                        }
                    }
                    
                }
                
            }
    
        if (imageBuffer) {
            [self displayPixelBuffer:imageBuffer withPresentationTime:framePTS];
            [self moveTimeLine];
        }
        
        
    }
}

/*
 Add a new sublayer for each image buffer based on the size of the pixel buffer
 Draw the pixelbuffer in the layer with OpenGLES
 */
- (void)displayPixelBuffer:(CVImageBufferRef)imageBuffer withPresentationTime:(NSNumber *)framePTS{
    int width = (int)CVPixelBufferGetWidth(imageBuffer);
    int height = (int)CVPixelBufferGetHeight(imageBuffer);
    CGFloat halfWidth = self.view.frame.size.width;
    CGFloat halfheight = self.view.frame.size.height;
    if (width > halfWidth || height > halfheight) {
        width /= 2;
        height /= 2;
    }
    
    AAPLEAGLLayer *layer = [[AAPLEAGLLayer alloc] init];
    if (self.videoPreferredTransform.a == -1.0f) {
        [layer setAffineTransform:CGAffineTransformRotate(layer.affineTransform, (180.0f * M_PI) / 180.0f)];
    } else if (self.videoPreferredTransform.a == 0.0f){
        [layer setAffineTransform:CGAffineTransformRotate(layer.affineTransform, (90.0f * M_PI) / 180.0f)];
    }
    [layer setFrame:CGRectMake(0.0f, self.view.frame.size.height - 50.0f - height, width, height)];
    layer.presentationRect = CGSizeMake(width, height);
    
    
    
    layer.timeCode = [NSString stringWithFormat:@"%.3f", [framePTS floatValue]];
    [layer setupGL];
    
    [self.view.layer addSublayer:layer];
    [layer displayPixelBuffer:imageBuffer];
    
}

#pragma mark - IBActions
- (IBAction)playButtonTapped:(id )sender {
    BOOL isPlaying = self.displayLink.isPaused;
    
    if (isPlaying == NO) {
        [self.displayLink setPaused:YES];
        [sender setTitle:@"Play"];
    } else{
        [self.displayLink setPaused:NO];
        [sender setTitle:@"Pause"];
        
    }
    
}

- (IBAction)chooseVideoTapped:(id)sender{
    NSLog(@"Choose video tapped.");
    AAPLImagePickerController *videoPicker = [[AAPLImagePickerController alloc] init];
    videoPicker.delegate = self;
    videoPicker.modalPresentationStyle = UIModalPresentationCurrentContext;
    videoPicker.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
    videoPicker.mediaTypes = @[(NSString*)kUTTypeMovie];
    
    //if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
    if(YES){
        self.popover = [[UIPopoverController alloc] initWithContentViewController:videoPicker];
        self.popover.delegate = self;
        [[self popover] presentPopoverFromBarButtonItem:sender permittedArrowDirections:UIPopoverArrowDirectionDown animated:YES];
    }
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController{
    self.popover.delegate = nil;
}

#pragma mark - Image Picker Controller Delegate
- (void)imagePickerController:(AAPLImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    [self.displayLink setPaused:YES];
    [self.playButton setTitle:@"Play"];
    [self.popover dismissPopoverAnimated:YES];
    [self.outputFrames removeAllObjects];
    [self.presentationTimes removeAllObjects];
    self.lastCallbackTime = 0.0;
    AVAsset *asset = [AVAsset assetWithURL:info[UIImagePickerControllerMediaURL]];
    if (self.assetReader.status == AVAssetReaderStatusReading) {
        dispatch_semaphore_signal(self.bufferSemaphore);
        [self.assetReader cancelReading];
    }
    
    dispatch_async(self.backgroundQueue, ^{
        [self readSampleBuffersFromAsset:asset];
    });
    
    
    picker.delegate = nil;
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [self dismissViewControllerAnimated:YES completion:nil];
    
    picker.delegate = nil;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

- (void)dealloc{
    CFRelease(_decompressionSession);
}

@end
