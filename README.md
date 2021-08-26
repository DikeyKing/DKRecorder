# DKRecorder

Swift Recorder to record UIView, idea from [ASScreenRecorder](https://github.com/alskipp/ASScreenRecorder)

## Intergate

   ```
      pod 'DKRecorder', :git=>'https://github.com/DikeyKing/DKRecorder.git', :tag => '0.1.1'
   ```
   
## Usage

1. if you can want to record a view, first init a recorder

   ```
       let recorder = DKRecorder.init()
   ```

2. then set the destination view you want to record

   ```
       self.recorder.startRecording()
       self.recorder.viewToCapture = self.view
   ```

3. And finish record by calling

   ```
       self.recorder.stopRecording {url in
          print("stopRecording url = \(url as Any)")
       }
   ```

4. And here is some settings can be changed

   ```
       self.recorder.recordAudio = false // you don't want to record audio 
       self.recorder.writeToPhotoLibrary = true // you don't want to save the video to library
   ```

5. See demo for detail

## Todo

1. Test cases
2. Record file Size Optimze

