# Training the spoof classifier

`Resources/Spoof.mlmodel` is a live/spoof image classifier run on the face crop (face plus margin). Class `0` is live, class `1` is spoof. `AntiSpoofGate` rejects at `defaultSpoofRejectThreshold`.

## Collect data

Use the dataset capture tool in Gaze. It saves the same crop the app scores, one folder per session, in `~/Documents/GazeDataset/<live|spoof>-<time>/`, with a `session.json` naming the label.

Record many short sessions, not a few long ones. The trainer holds out whole sessions, so one long session teaches less and tests nothing.

Live sessions (aim for 20 or more):

- Your own face at arm's length, closer, and leaning back
- Daylight, lamp only, dark room lit by the screen
- With and without glasses, a hat, headphones
- Other people too, if they agree

Spoof sessions (aim for 20 or more, at least 4 of each kind):

- A photo of you on a phone screen, full brightness and dimmed
- A photo or video of you on a laptop or tablet screen
- A printed photo, matte and glossy, flat and slightly curved
- Each at 20, 40 and 60 cm, and under the same lighting as the live sessions

Keep each session to one kind of thing in front of the camera. Fill in what is in front of the camera (for example "iPhone 14 screen", "printed A4") so `session.json` records it.

A few hundred crops per class across those sessions is the least worth training on. The current own-camera set is 3 live and 2 spoof sessions (91 and 60 crops), which is too small to trust.

## Train

```
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift Tools/Scripts/train-spoof-classifier.swift \
    --sessions ~/Documents/GazeDataset \
    --frames ~/Developer/Gaze-dev-archive/build-old-20260926/model-lab-20260913/dataset-expanded \
    --work /tmp/spoof-work \
    --out outputs/spoof-models/Spoof-classifier.mlmodel \
    --metrics outputs/spoof-models/metrics.json \
    --old Resources/Spoof.mlmodel
```

`--frames` adds the Roboflow frames (CC BY 4.0, split by subject), cropped with Vision the way the app crops. Leave it out to train on your own sessions only.

The metrics JSON has spoof recall and live false-reject rate at every threshold from 0.05 to 0.95, for the new model and the bundled one, on each held-out set.

## Ship

Replace `Resources/Spoof.mlmodel` only when the new model catches more spoofs at the same or a lower live false-reject rate on both held-out sets. Move the threshold in `AntiSpoofGate` to the point that holds that, and update the table above it. Keep old models in `outputs/spoof-models/`, not in `Resources/`.
