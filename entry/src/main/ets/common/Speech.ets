import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { audio } from '@kit.AudioKit'
import { speechRecognizer } from '@kit.CoreSpeechKit'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * Offline speech-to-text for the composer.
 *
 * HarmonyOS ships CoreSpeechKit in the HMS SDK (`hms/ets/kits`), which is a
 * different directory from the OpenHarmony kits — that is why an earlier note
 * in this repo wrongly recorded voice input as impossible.
 *
 * Two rules shape this file:
 *
 *   1. Capability is checked at runtime with `canIUse`, never assumed. A device
 *      without `SystemCapability.AI.SpeechRecognizer` must hide the microphone
 *      rather than offer a button that throws.
 *   2. The engine is created lazily and released after each utterance. It holds
 *      the microphone; leaving it alive keeps the input device busy and drains
 *      the battery between the rare moments someone actually speaks.
 */

/** What the caller sees while dictating. */
export interface SpeechCallbacks {
  /** Interim text, replacing whatever was shown last. */
  onPartial: (text: string) => void
  /** Final text for this utterance. */
  onFinal: (text: string) => void
  /** Non-recoverable failure; the caller shows the message and hides the button. */
  onError: (message: string) => void
}

/** Whether this device can do offline Chinese speech recognition. */
export function speechSupported(): boolean {
  try {
    return canIUse('SystemCapability.AI.SpeechRecognizer')
  } catch (error) {
    return false
  }
}

/**
 * Ask for the microphone, once.
 *
 * `requestPermissionsFromUser` shows nothing when the user already answered, so
 * a denied permission surfaces as `false` rather than as a dialog on every tap.
 */
export async function requestMicPermission(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const manager = abilityAccessCtrl.createAtManager()
    const result = await manager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE'])
    return result.authResults.length > 0 && result.authResults[0] === 0
  } catch (error) {
    return false
  }
}

export class SpeechInput {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null
  private capturer: audio.AudioCapturer | null = null
  /**
   * The engine does not open the microphone itself: `startListening` only
   * prepares a session and every 640- or 1280-byte `writeAudio` is one slice of
   * the utterance. Without a capturer feeding it, recognition "starts" and then
   * produces no text at all (the failure mode this class shipped with).
   */
  private pcm: Uint8Array = new Uint8Array(0)
  private listening: boolean = false
  /** The id of the utterance in flight; `finish()` requires it back. */
  private sessionId: string = ''

  /**
   * Start one utterance.
   *
   * `sessionId` only has to be unique per utterance; the engine uses it to tie
   * callbacks back to this request.
   */
  start(callbacks: SpeechCallbacks): void {
    if (!speechSupported()) {
      callbacks.onError('本机不支持离线语音识别')
      return
    }
    if (this.listening) {
      return
    }
    const params: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN',
      // `1` means offline, which is the only mode Core Speech Kit exposes
      // (`CreateEngineParams.online`: "1: offline. Currently, only the offline
      // mode is supported."). Sending 0 asks for the online mode that does not
      // exist here, and createEngine answers 1002200001 "engine creation
      // failed / mode not supported" — the same code a missing voice pack
      // produces, which is why this looked like a missing download.
      online: 1,
      extraParams: {}
    }
    try {
      speechRecognizer.createEngine(params, (error: BusinessError, engine: speechRecognizer.SpeechRecognitionEngine) => {
        if (error !== null && error !== undefined) {
          // The syscap can be present while the offline Chinese model is not:
          // the engine then fails to construct (device log: "Failed to create
          // engine [callback]"). Say what is missing instead of a bare code —
          // the fix is on the system side, not in this app.
          callbacks.onError(`语音引擎启动失败（${error.code}），语音识别暂不可用`)
          return
        }
        this.engine = engine
        this.bind(engine, callbacks)
        try {
          this.sessionId = `dsh-${Date.now()}`
          // PCM 16 kHz mono is the only shape the offline engine accepts; the
          // channel is 1 (mono) and the type names the encoding, not a file.
          engine.startListening({
            sessionId: this.sessionId,
            audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 }
          })
          this.listening = true
          this.openCapture(callbacks)
        } catch (startError) {
          this.release()
          callbacks.onError('无法开始录音')
        }
      })
    } catch (error) {
      callbacks.onError('语音引擎不可用')
    }
  }

  /** Stop early and keep whatever was recognised so far. */
  stop(): void {
    this.stopCapture()
    if (this.engine === null || !this.listening) {
      return
    }
    try {
      this.engine.finish(this.sessionId)
    } catch (error) {
      // A finish on a finished engine is not worth reporting.
    }
    this.listening = false
  }

  /**
   * Start PCM capture and stream it into the engine.
   *
   * Two hard rules from the API: the audio must be 16 kHz mono PCM S16LE, and
   * `writeAudio` accepts only 640- or 1280-byte slices, so the capturer's
   * arbitrary callback size is re-chunked here. A trailing partial slice is
   * padded with silence so the last word is not dropped.
   */
  private async openCapture(callbacks: SpeechCallbacks): Promise<void> {
    try {
      const options: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_MIC,
          capturerFlags: 0
        }
      }
      const capturer = await audio.createAudioCapturer(options)
      capturer.on('readData', (buffer: ArrayBuffer) => {
        this.feedPcm(buffer)
      })
      await capturer.start()
      this.capturer = capturer
    } catch (error) {
      this.release()
      callbacks.onError('无法打开麦克风（录音器启动失败）')
    }
  }

  /** Append captured bytes and push complete 1280-byte slices to the engine. */
  private feedPcm(buffer: ArrayBuffer): void {
    const engine = this.engine
    if (engine === null || !this.listening) {
      return
    }
    const incoming = new Uint8Array(buffer)
    const merged = new Uint8Array(this.pcm.length + incoming.length)
    merged.set(this.pcm, 0)
    merged.set(incoming, this.pcm.length)
    let offset = 0
    const slice = 1280
    while (merged.length - offset >= slice) {
      try {
        engine.writeAudio(this.sessionId, merged.subarray(offset, offset + slice))
      } catch (error) {
        this.stopCapture()
        return
      }
      offset += slice
    }
    this.pcm = merged.subarray(offset)
  }

  private stopCapture(): void {
    // Flush what is left, padded to a legal size, so the tail is not lost.
    if (this.engine !== null && this.listening && this.pcm.length > 0) {
      const padded = new Uint8Array(1280)
      padded.set(this.pcm.subarray(0, Math.min(this.pcm.length, 1280)), 0)
      try {
        this.engine.writeAudio(this.sessionId, padded)
      } catch (error) {
        // Session may already be closing; the finish below settles it.
      }
    }
    this.pcm = new Uint8Array(0)
    const capturer = this.capturer
    this.capturer = null
    if (capturer !== null) {
      capturer.stop().catch(() => {})
      capturer.release().catch(() => {})
    }
  }

  /** Drop the engine and free the microphone. */
  release(): void {
    this.stopCapture()
    if (this.engine === null) {
      return
    }
    try {
      this.engine.shutdown()
    } catch (error) {
      // Already shut down.
    }
    this.engine = null
    this.listening = false
  }

  private bind(engine: speechRecognizer.SpeechRecognitionEngine, callbacks: SpeechCallbacks): void {
    engine.setListener({
      onStart: (sessionId: string, eventMessage: string) => {},
      onEvent: (sessionId: string, eventCode: number, eventMessage: string) => {},
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
        const text = result.result
        if (result.isFinal) {
          callbacks.onFinal(text)
          this.release()
        } else {
          callbacks.onPartial(text)
        }
      },
      onComplete: (sessionId: string, eventMessage: string) => {
        this.release()
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string) => {
        this.release()
        callbacks.onError(`识别失败（${errorCode}）`)
      }
    })
  }
}
