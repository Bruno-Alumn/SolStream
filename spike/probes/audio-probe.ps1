# audio-probe.ps1 — make a noise on the host, so loopback capture has something
# to capture.
#
# WASAPI loopback produces NOTHING while the audio engine is idle: not silence,
# no buffers at all. So "0 packets sent, 0 silent" on the host means either the
# capture is broken or nothing was playing, and those have to be told apart by
# making something play.
#
# Interactive scheduled task only. A process in session 0 renders into session
# 0's audio, which is not the endpoint the console session's loopback sees.

param(
    [int]$Repeats = 12,
    [string]$Wav = "C:\Windows\Media\Alarm03.wav"
)

$player = New-Object System.Media.SoundPlayer $Wav
for ($i = 0; $i -lt $Repeats; $i++) {
    $player.PlaySync()
}
