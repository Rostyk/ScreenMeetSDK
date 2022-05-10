//
//  SMTrackBuilder.swift
//  ScreenMeet
//
//  Created by Ross on 22.02.2021.
//

import UIKit
import WebRTC

class SMTracksManager: NSObject {
    var videoSourceDevice: AVCaptureDevice?    
    private var mediaStream: RTCMediaStream!
    private var videoSource: RTCVideoSource!
    private var videoTrack: RTCVideoTrack!
    private var audioTrack: RTCAudioTrack!
    
    private var videoCapturer: SMVideoCapturer!
    
    private var factory: RTCPeerConnectionFactory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    
    func makeVideoTrack() -> RTCVideoTrack {
        if mediaStream == nil {
            self.mediaStream = self.factory.mediaStream(withStreamId: "0")
        }
                
        videoSource = factory.videoSource()
        
        videoTrack = factory.videoTrack(with: videoSource, trackId: "ARDAMSv0")
        self.mediaStream.addVideoTrack(videoTrack)        
        return videoTrack
    }
    
    func makeAudioTrack() -> RTCAudioTrack {
        audioTrack = factory.audioTrack(withTrackId: "ARDAMSa0")
        audioTrack.isEnabled = true
        
        if mediaStream == nil {
            self.mediaStream = self.factory.mediaStream(withStreamId: "0")
        }
        
        self.mediaStream.addAudioTrack(audioTrack)
        return audioTrack
    }
    
    /// Captureres
    
    func startCapturer(_ videoSourceDevice: AVCaptureDevice?, _ completionHandler: SMCapturerOperationCompletion? = nil) {
        if (videoCapturer != nil) {
            //TODO
            print("Video capturer already started")
            completionHandler?(nil)
            return
        }
        
        videoCapturer = VideoCapturerFactory.videoCapturer(videoSourceDevice, delegate: self)
        videoCapturer.delegate = nil
        videoCapturer.startCapture() { [weak self] error in
            if let error = error {
                completionHandler?(error)
            }
            else {
                if #available(iOS 13.0, *) {
                    let captureSessionConnections = self?.videoCapturer.getCaptureSession().connections
                    captureSessionConnections?.first?.videoOrientation = .portrait
                    
                    completionHandler?(nil)
                    self?.videoCapturer.delegate = self
                    
                }
                else {
                    completionHandler?(SMError(code: .capturerInternalError, message: "Unsupported iOS version"))
                }
            }
            
        }
    }

    func stopCapturer(completionHandler: SMCapturerOperationCompletion? = nil) {
        if (videoCapturer == nil) {
            // Video capturer already stopped
            completionHandler?(nil)
            return
        }
        
        videoCapturer.stopCapture(completionHandler)
    }
    
    func cleanupVideo() {
        if (self.videoCapturer != nil) {
            self.videoCapturer.stopCapture { error in
                
            }
        }
       
        self.videoCapturer = nil
        if (self.videoTrack != nil) {
            if (self.mediaStream != nil)  {
                self.mediaStream.removeVideoTrack(videoTrack)
            }
        }
        self.mediaStream = nil
        self.videoTrack = nil
        self.videoSource = nil
    }
    
    func cleanupAudio() {
        if (self.audioTrack != nil) {
            if (self.mediaStream != nil)  {
                self.mediaStream.removeAudioTrack(audioTrack)
            }
            
            self.audioTrack.isEnabled = false
            self.audioTrack = nil
        }
    }

    func changeCapturer(_ videoSourceDevice: AVCaptureDevice!, _ completionHandler: SMCapturerOperationCompletion? = nil) {
        if (videoCapturer != nil) {
            videoCapturer.delegate = nil
            videoCapturer.stopCapture({ [weak self] error in
                guard error == nil else {
                    completionHandler?(error)
                    return
                }
                
                let newCapturer = VideoCapturerFactory.videoCapturer(videoSourceDevice, delegate: self!)
                newCapturer.delegate = nil
                newCapturer.startCapture({error in
                    guard error == nil else {
                        completionHandler?(error)
                        return
                    }
                    if #available(iOS 13.0, *) {
                        let captureSessionConnections = newCapturer.getCaptureSession().connections
                        captureSessionConnections.first?.videoOrientation = .portrait
                    }
                    
                    newCapturer.delegate = self
                    completionHandler?(error)
                })
                self?.videoCapturer = newCapturer
            })
        } else {
            let newCapturer = VideoCapturerFactory.videoCapturer(videoSourceDevice, delegate: self)
            newCapturer.startCapture({error in
                guard error == nil else {
                    completionHandler?(error)
                    return
                }
                newCapturer.startCapture(nil)
                self.videoCapturer = newCapturer
            })
        }
    }
    
    func getVideoSourceDevice() -> AVCaptureDevice? {
        if let cameraCapturer = self.videoCapturer as? CameraVideoCapturer {
            return cameraCapturer.device
        }
        return nil
    }
    
    func createImageTransferHandler() -> SMImageHandler {
        
        videoSourceDevice = nil
        videoCapturer = VideoCapturerFactory.fakeCapturer()
                                      
        let handler = SMImageHandler()
        handler.imageHandler = { [unowned self] image in
            let rotation = RTCVideoRotation._0
            let timeStampNs: Int64 = Int64(Date().timeIntervalSince1970 * 1000000000)
            
            let rtcpixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBufferFromImage(image))
            let frame = RTCVideoFrame(buffer:rtcpixelBuffer, rotation: rotation, timeStampNs: timeStampNs)
            self.capturer(videoCapturer, didCapture: frame)
        }
        return handler
    }
    
    func pixelBufferFromImage(_ image: UIImage) -> CVPixelBuffer {
            let ciimage = CIImage(image: image)
            //let cgimage = convertCIImageToCGImage(inputImage: ciimage!)
            let tmpcontext = CIContext(options: nil)
            let cgimage =  tmpcontext.createCGImage(ciimage!, from: ciimage!.extent)
            
            let cfnumPointer = UnsafeMutablePointer<UnsafeRawPointer>.allocate(capacity: 1)
            let cfnum = CFNumberCreate(kCFAllocatorDefault, .intType, cfnumPointer)
            let keys: [CFString] = [kCVPixelBufferCGImageCompatibilityKey, kCVPixelBufferCGBitmapContextCompatibilityKey, kCVPixelBufferBytesPerRowAlignmentKey]
            let values: [CFTypeRef] = [kCFBooleanTrue, kCFBooleanTrue, cfnum!]
            let keysPointer = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
            let valuesPointer =  UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
            keysPointer.initialize(to: keys)
            valuesPointer.initialize(to: values)
            
            let options = CFDictionaryCreate(kCFAllocatorDefault, keysPointer, valuesPointer, keys.count, nil, nil)
           
            let width = cgimage!.width
            let height = cgimage!.height
         
            var pxbuffer: CVPixelBuffer?
            // if pxbuffer = nil, you will get status = -6661
            var status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                             kCVPixelFormatType_32BGRA, options, &pxbuffer)
            status = CVPixelBufferLockBaseAddress(pxbuffer!, CVPixelBufferLockFlags(rawValue: 0));
            
            let bufferAddress = CVPixelBufferGetBaseAddress(pxbuffer!);

            
            let rgbColorSpace = CGColorSpaceCreateDeviceRGB();
            let bytesperrow = CVPixelBufferGetBytesPerRow(pxbuffer!)
            let context = CGContext(data: bufferAddress,
                                    width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: bytesperrow,
                                    space: rgbColorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue);
            context?.concatenate(CGAffineTransform(rotationAngle: 0))
            context?.concatenate(__CGAffineTransformMake( 1, 0, 0, -1, 0, CGFloat(height) )) //Flip Vertical
    //        context?.concatenate(__CGAffineTransformMake( -1.0, 0.0, 0.0, 1.0, CGFloat(width), 0.0)) //Flip Horizontal
            

            context?.draw(cgimage!, in: CGRect(x:0, y:0, width:CGFloat(width), height:CGFloat(height)));
            status = CVPixelBufferUnlockBaseAddress(pxbuffer!, CVPixelBufferLockFlags(rawValue: 0));
            return pxbuffer!;
            
        }
    
    private func buffer(from image: UIImage) -> CVPixelBuffer? {
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue, kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        var pixelBuffer : CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(image.size.width), Int(image.size.height), kCVPixelFormatType_32ARGB, attrs, &pixelBuffer)
        guard (status == kCVReturnSuccess) else {
          return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer!)

        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: pixelData, width: Int(image.size.width), height: Int(image.size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)

        context?.translateBy(x: 0, y: image.size.height)
        context?.scaleBy(x: 1.0, y: -1.0)

        UIGraphicsPushContext(context!)
        image.draw(in: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        UIGraphicsPopContext()
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))

        return pixelBuffer
      }
}

extension SMTracksManager: RTCVideoCapturerDelegate {
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        DispatchQueue.main.async {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        }
        self.videoSource?.capturer(capturer, didCapture: frame)
    }
}
