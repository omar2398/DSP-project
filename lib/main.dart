import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:animated_notch_bottom_bar/animated_notch_bottom_bar/animated_notch_bottom_bar.dart';
import 'package:fft/fft.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart' as chart;
import 'package:mic_stream/mic_stream.dart';
import 'dart:developer';

enum Command {
  start,
  stop,
  change,
}

void main() => runApp(const MicStreamExampleApp());

class MicStreamExampleApp extends StatefulWidget {
  const MicStreamExampleApp({Key? key}) : super(key: key);

  @override
  State<MicStreamExampleApp> createState() => _MicStreamExampleAppState();
}

class _MicStreamExampleAppState extends State<MicStreamExampleApp>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Stream<Uint8List>? _stream;
  int page = 0;
  StreamSubscription<Uint8List>? _soundSubscription;
  final _spots = StreamController<List<chart.FlSpot>>.broadcast();
  final _fftSpots = StreamController<List<chart.FlSpot>>.broadcast();
  double _maxTimeValue = 1;
  double _maxFFTValue = 1;
  bool memRecordingState = false;
  bool isRecording = false;
  bool isActive = false;
  @override
  void initState() {
    log("Init application");
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    setState(() {
      initPlatformState();
    });
  }

  // Responsible for switching between recording / idle state
  void _controlMicStream({Command command = Command.change}) async {
    switch (command) {
      case Command.change:
        _changeListening();
        break;
      case Command.start:
        _startListening();
        break;
      case Command.stop:
        _stopListening();
        break;
    }
  }

  Future<bool> _changeListening() async => !isRecording ? await _startListening() : _stopListening();

  late int bytesPerSample;
  late int samplesPerSecond;
  final _pageController = PageController(initialPage: 0);
  final _controller = NotchBottomBarController(index: 0);

  Future<bool> _startListening() async {
    log("START LISTENING");
    if (isRecording) return false;
    // if this is the first time of running the microphone()
    // method to get the stream, we don't yet have access(start getting access ya man)
    // to the sampleRate and bitDepth properties
    log("wait for stream");

    // Default option. Set to false to disable request permission dialogue
    MicStream.shouldRequestPermission(true); //this the permission of mic only

    _stream = await MicStream.microphone(
      audioSource: AudioSource.DEFAULT,
      sampleRate: 44100, //a standard sample rate is 44.1 kHz or 44,100 samples per second. This is the standard for most consumer audio, used for formats like CDs. 48 kHz is another common audio sample rate used for movies.
      channelConfig: ChannelConfig.CHANNEL_IN_MONO,// to be not frmo stereo
      audioFormat: AudioFormat.ENCODING_PCM_16BIT,//each sample will be number in 16bit form and also can be 8bit -> bit depth
    );
    // after invoking the method for the first time, though, these will be available;
    // It is not necessary to setup a listener first, the stream only needs to be returned first
    log("Start Listening to the microphone, sample rate is ${await MicStream.sampleRate}, bit depth is ${await MicStream.bitDepth}, bufferSize: ${await MicStream.bufferSize}");
    bytesPerSample = (await MicStream.bitDepth)! ~/ 8;
    samplesPerSecond = (await MicStream.sampleRate)!.toInt();
    _maxFFTValue = 1;
    _maxTimeValue = 1;

    setState(() {
      isRecording = true;
    });
    _soundSubscription = _stream!.listen(_micListener);
    return true;
  }

  bool _mutex = false;
  void _micListener(Uint8List f) async {
    if (_mutex) return;
    _mutex = true;
    final computedData = await compute<List, List>((List f) {
      final data = _calculateWaveSamples(f[0] as Uint8List);
      double maxTimeValue = f[1];
      double maxFFTValue = f[2];
      final sampleRate = (f[3] as int).toDouble();
      int initialPowerOfTwo = (math.log(data.length) * math.log2e).ceil();
      int samplesFinalLength = math.pow(2, initialPowerOfTwo).toInt();
      final padding = List<double>.filled(samplesFinalLength - data.length, 0);
      final fftSamples = FFT().Transform([...data, ...padding]);
      final deltaTime = 1E6 / (sampleRate * fftSamples.length);
      final timeSpots = List<chart.FlSpot>.generate(data.length, (n) {
        final y = data[n];
        maxTimeValue = math.max(maxTimeValue, y);
        return chart.FlSpot(n * deltaTime, y);
      });
      final deltaFrequency = sampleRate / fftSamples.length;
      final frequencySpots = List<chart.FlSpot>.generate(
        1 + fftSamples.length ~/ 2,
        (n) {
          double y = fftSamples[n]!.abs();
          maxFFTValue = math.max(maxFFTValue, y);
          return chart.FlSpot(n * deltaFrequency, y);
        },
      );
      return [maxTimeValue, timeSpots, maxFFTValue, frequencySpots];
    }, [f, _maxTimeValue, _maxFFTValue, samplesPerSecond]);
    _mutex = false;
    _maxTimeValue = computedData[0];
    _spots.add(computedData[1]);
    _maxFFTValue = computedData[2];
    _fftSpots.add(computedData[3]);
  }

  static List<double> _calculateWaveSamples(Uint8List samples) {
    final x = List<double>.filled(samples.length ~/ 2, 0);
    for (int i = 0; i < x.length; i++) {
      int msb = samples[i * 2 + 1];
      int lsb = samples[i * 2];
      if (msb > 128) msb -= 255;
      if (lsb > 128) lsb -= 255;
      x[i] = lsb + msb * 128;
    }
    return x;
  }

  bool _stopListening() {
    if (!isRecording) return false;
    log("Stop Listening to the microphone");
    _soundSubscription?.cancel();

    setState(() {
      isRecording = false;
    });
    return true;
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    if (!mounted) return;
    isActive = true;
  }

  Color _getBgColor() => (isRecording) ? Colors.amber : Colors.redAccent;
  Icon _getIcon() => (isRecording) ? const Icon(Icons.stop,size: 35,) : const Icon(Icons.keyboard_voice,size: 35,);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          backgroundColor: Colors.black26,
          appBar: AppBar(
            title: const Text('Omaranko',style: TextStyle(fontSize: 25),),
            actions: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 50),
                  child: ElevatedButton(
                    style: ButtonStyle(
                      backgroundColor: MaterialStateProperty.resolveWith<Color>(
                            (Set<MaterialState> states) {
                          return !isRecording ? Colors.grey : Colors.redAccent;
                        },
                      ),
                    ),
                    onPressed:_controlMicStream,
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(2),
                          child: CircleAvatar(child: Icon(_getIcon().icon,color: _getBgColor(),size: 30,),backgroundColor: Colors.white,),
                        ),
                        SizedBox(width: 5,),
                        (!isRecording) ? Text('start recording bro') : Text('stop recording bro')
                      ],
                    ),
                  ),
                ),
              ),
              // Padding(
              //   padding: const EdgeInsets.only(right: 50),
              //   child: CircleAvatar(
              //     backgroundColor: Colors.white,
              //     child: IconButton(
              //       onPressed: _controlMicStream,
              //       icon: _getIcon(),
              //       color: _getBgColor(),
              //       tooltip: (isRecording) ? "Stop recording" : "Start recording",
              //     ),
              //   ),
              // )
            ],
          ),
          bottomNavigationBar: BottomNavigationBar(
            items:  [
              BottomNavigationBarItem(
                icon: Icon(Icons.broken_image),
                label: "Time Domain Signal",
                activeIcon: Icon(Icons.broken_image,size: 40,color: Colors.red,),
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.bar_chart),
                label: "Frequency Domain Signal",
                activeIcon: Icon(Icons.bar_chart,size: 40,color: Colors.red)
              ),
            ],
            backgroundColor: Colors.grey.shade900,
            selectedLabelStyle: TextStyle(
              color: Colors.red
            ),
            showSelectedLabels: false,
            elevation: 20,
            currentIndex: page,
            onTap: (v) => setState(() => page = v),
          ),
          body: [
            StreamBuilder<List<chart.FlSpot>>(
              stream: _spots.stream,
              builder: (context, snapshot) {
                if (snapshot.data == null) {
                  return Container();
                }

                return chart.LineChart(
                  chart.LineChartData(
                    backgroundColor: Colors.black38,
                    lineBarsData: [
                      chart.LineChartBarData(
                        spots: snapshot.data!,
                        color: Colors.redAccent,
                        dotData: chart.FlDotData(show: false),
                      ),
                    ],
                    maxY: _maxTimeValue,
                    minY: -_maxTimeValue,
                  ),
                );
              },
              key: const ValueKey(0),
            ),
            StreamBuilder<List<chart.FlSpot>>(
              stream: _fftSpots.stream,
              builder: (context, snapshot) {
                if (snapshot.data == null) {
                  return Container();
                }

                return chart.LineChart(
                  chart.LineChartData(
                    backgroundColor: Colors.black38,
                    lineBarsData: [
                      chart.LineChartBarData(
                        color: Colors.redAccent,
                        spots: snapshot.data!,
                        dotData: chart.FlDotData(show: false),
                      ),
                    ],
                    maxY: _maxFFTValue,
                    minY: 0,
                  ),
                );
              },
              key: const ValueKey(1),
            )
          ][page],
        ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      isActive = true;
      log("Resume app");

      _controlMicStream(command: memRecordingState ? Command.start : Command.stop);
    } else if (isActive) {
      memRecordingState = isRecording;
      _controlMicStream(command: Command.stop);

      log("Pause app");
      isActive = false;
    }
  }

  @override
  void dispose() {
    _soundSubscription?.cancel();

    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
