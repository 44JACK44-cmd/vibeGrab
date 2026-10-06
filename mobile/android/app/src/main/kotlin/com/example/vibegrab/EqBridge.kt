package com.example.vibegrab

import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer

/**
 * VibeGrab: real hardware/DSP equalizer bound to the app's audio session.
 *
 * just_audio publishes its AudioSessionId; we attach an [Equalizer],
 * [BassBoost] and [LoudnessEnhancer] to it so the user hears the change
 * instantly on every output (speaker, wired, Bluetooth, ...).
 * Session id 0 = global output mix (used for video playback, where the
 * player does not expose a session id).
 */
object EqBridge {
    private var sessionId: Int = -1
    private var eq: Equalizer? = null
    private var bass: BassBoost? = null
    private var loud: LoudnessEnhancer? = null

    @Synchronized
    fun info(): Map<String, Any?> {
        val e = eq ?: return mapOf("ok" to false)
        return try {
            val n = e.numberOfBands.toInt()
            val freqs = (0 until n).map { e.getCenterFreq(it.toShort()) / 1000 }
            val presets =
                (0 until e.numberOfPresets.toInt()).map { e.getPresetName(it.toShort()) }
            mapOf(
                "ok" to true,
                "bands" to n,
                "minMb" to e.bandLevelRange[0].toInt(),
                "maxMb" to e.bandLevelRange[1].toInt(),
                "freqs" to freqs,
                "presets" to presets
            )
        } catch (ex: Exception) {
            mapOf("ok" to false)
        }
    }

    @Synchronized
    fun attach(sid: Int): Boolean {
        if (sid == sessionId && eq != null) return true
        release()
        return try {
            sessionId = sid
            eq = Equalizer(0, sid).apply { enabled = true }
            try {
                bass = BassBoost(0, sid)
            } catch (_: Exception) {
            }
            try {
                loud = LoudnessEnhancer(sid)
            } catch (_: Exception) {
            }
            true
        } catch (e: Exception) {
            release()
            false
        }
    }

    @Synchronized
    fun setEnabled(v: Boolean) {
        try {
            eq?.enabled = v
        } catch (_: Exception) {
        }
    }

    @Synchronized
    fun setBand(band: Int, levelMb: Int) {
        try {
            val e = eq ?: return
            if (band < 0 || band >= e.numberOfBands) return
            e.setBandLevel(band.toShort(), levelMb.toShort())
        } catch (_: Exception) {
        }
    }

    @Synchronized
    fun setPreset(i: Int) {
        try {
            eq?.usePreset(i.toShort())
        } catch (_: Exception) {
        }
    }

    @Synchronized
    fun setBass(s: Int) {
        try {
            bass?.setStrength(s.coerceIn(0, 1000).toShort())
        } catch (_: Exception) {
        }
    }

    @Synchronized
    fun setLoudness(mb: Int) {
        try {
            loud?.setTargetGain(mb)
        } catch (_: Exception) {
        }
    }

    @Synchronized
    fun releaseAll() {
        try {
            eq?.release()
        } catch (_: Exception) {
        }
        try {
            bass?.release()
        } catch (_: Exception) {
        }
        try {
            loud?.release()
        } catch (_: Exception) {
        }
        eq = null
        bass = null
        loud = null
        sessionId = -1
    }

    private fun release() = releaseAll()
}
