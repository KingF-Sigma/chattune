// Musik im Mikrofon: nimmt NUR den Ton von Spotify ab (Windows "Process Loopback", also ohne VRChat-Sounds),
// mischt ihn mit deinem echten Mikrofon und spielt beides in ein virtuelles Kabel (z. B. VB-CABLE).
// In VRChat stellt man dann "CABLE Output" als Mikrofon ein.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace MusicMicAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class MMDeviceEnumeratorCom { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }
    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    }
    [StructLayout(LayoutKind.Sequential)] public struct PropertyKey { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Sequential)] public struct PropVariant { public short vt; public short r1, r2, r3; public IntPtr p; public IntPtr p2; }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioClient {
        [PreserveSig] int Initialize(int shareMode, uint flags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint padding);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }
    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioCaptureClient {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }
    [ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioRenderClient {
        [PreserveSig] int GetBuffer(uint frames, out IntPtr data);
        [PreserveSig] int ReleaseBuffer(uint frames, uint flags);
    }
    [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IActivateAudioInterfaceAsyncOperation {
        void GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
    }
    [ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IActivateAudioInterfaceCompletionHandler {
        void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation);
    }
    [ComImport, Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAgileObject { }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public class ActivationHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject {
        public readonly ManualResetEvent Done = new ManualResetEvent(false);
        public int Result; public object Client;
        public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation) {
            try { operation.GetActivateResult(out Result, out Client); } catch (Exception e) { Result = e.HResult; }
            Done.Set();
        }
    }

    // Einfacher Ringpuffer fuer Stereo-Samples (float, verschachtelt L R L R ...)
    public class SampleQueue {
        readonly float[] buf; int read, count;
        public bool Primed;
        public SampleQueue(int capacity) { buf = new float[capacity]; }
        public int Count { get { return count; } }
        public void Push(float s) {
            if (count == buf.Length) { read = (read + 1) % buf.Length; count--; }
            buf[(read + count) % buf.Length] = s; count++;
        }
        public float Pop() { if (count == 0) return 0f; float s = buf[read]; read = (read + 1) % buf.Length; count--; return s; }
        public void Drop(int n) { n = Math.Min(n, count); read = (read + n) % buf.Length; count -= n; }
        public void Clear() { read = 0; count = 0; Primed = false; }
    }

    public static class MusicMic {
        const int Rate = 48000, Channels = 2;
        const uint AUTOCONVERT = 0x80000000, SRC_QUALITY = 0x08000000, LOOPBACK = 0x00020000, EVENTCALLBACK = 0x00040000;
        static Guid IID_IAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
        static Guid IID_Capture = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
        static Guid IID_Render = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
        static PropertyKey PKEY_FriendlyName = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };

        [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = false)]
        static extern void ActivateAudioInterfaceAsync([MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
            [MarshalAs(UnmanagedType.LPStruct)] Guid riid, IntPtr activationParams,
            IActivateAudioInterfaceCompletionHandler completionHandler, out IActivateAudioInterfaceAsyncOperation activationOperation);
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant pv);

        // ---------- Einstellungen (vom Panel jederzeit aenderbar) ----------
        public static volatile float MusicVolume = 0.6f;   // 0..2
        public static volatile float VoiceVolume = 1.0f;   // 0..2
        public static volatile bool Normalize = true;      // Songs gleich laut
        public static volatile bool Duck = true;           // Musik leiser, wenn du sprichst
        public static volatile bool UseVoice = true;       // echtes Mikrofon mit hineinmischen
        public static volatile float GateStrength = 0.5f;  // Rauschsperre 0 = aus .. 1 = stark
        public static volatile bool VoiceOpen;             // Rauschsperre gerade offen (du sprichst)
        public static volatile string MicId = "";          // "" = Windows-Standardmikrofon
        public static volatile string CableId = "";        // "" = automatisch suchen
        public static volatile string ProcessName = "Spotify";

        // ---------- Zustand fuers Panel ----------
        public static volatile string Status = "off";      // off, nocable, ok, error
        public static volatile string Error = "";
        public static volatile string CableName = "", MicName = "";
        public static volatile bool MusicAttached;
        public static volatile float MusicLevel, VoiceLevel, OutLevel;   // 0..1, fallen langsam ab
        public static volatile bool Restart;

        static Thread thread;
        static volatile bool running;
        public static bool IsRunning { get { return running; } }

        public static void Start() {
            if (running) return;
            running = true; Restart = false;
            thread = new Thread(Run) { IsBackground = true, Priority = ThreadPriority.AboveNormal, Name = "MusicMic" };
            thread.SetApartmentState(ApartmentState.MTA);
            thread.Start();
        }
        public static void Stop() {
            running = false;
            if (thread != null) { thread.Join(2000); thread = null; }
            Status = "off"; MusicLevel = VoiceLevel = OutLevel = 0; MusicAttached = false;
        }

        // ---------- Geraete ----------
        // flow: 0 = Ausgabe (Lautsprecher/Kabel), 1 = Eingabe (Mikrofone). Ergebnis: "id<TAB>Name"
        public static string[] GetDevices(int flow) {
            var list = new List<string>();
            var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            IMMDeviceCollection col;
            if (en.EnumAudioEndpoints(flow, 1, out col) != 0) return list.ToArray();
            int n; col.GetCount(out n);
            for (int i = 0; i < n; i++) {
                IMMDevice dev; if (col.Item(i, out dev) != 0) continue;
                string id; dev.GetId(out id);
                list.Add(id + "\t" + GetName(dev));
                Marshal.ReleaseComObject(dev);
            }
            Marshal.ReleaseComObject(col); Marshal.ReleaseComObject(en);
            return list.ToArray();
        }
        static string GetName(IMMDevice dev) {
            IPropertyStore store;
            if (dev.OpenPropertyStore(0, out store) != 0) return "";
            PropVariant v; var key = PKEY_FriendlyName;
            string name = "";
            if (store.GetValue(ref key, out v) == 0) { if (v.vt == 31) name = Marshal.PtrToStringUni(v.p); PropVariantClear(ref v); }
            Marshal.ReleaseComObject(store);
            return name;
        }
        public static bool IsCableName(string name) {
            string n = (name ?? "").ToLowerInvariant();
            return n.Contains("cable input") || n.Contains("cable in ") || n.Contains("vb-audio virtual") || n.Contains("voicemeeter input")
                || n.Contains("voicemeeter aux input") || n.Contains("voicemeeter vaio3 input");
        }
        public static string FindCable() {
            foreach (var d in GetDevices(0)) { var p = d.Split('\t'); if (p[1].ToLowerInvariant().Contains("cable input")) return d; }
            foreach (var d in GetDevices(0)) { var p = d.Split('\t'); if (IsCableName(p[1])) return d; }
            return null;
        }

        // ---------- Prozess finden (oberster Spotify-Prozess, Kindprozesse zaehlen mit) ----------
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct PROCESSENTRY32 {
            public int dwSize; public int cntUsage; public int th32ProcessID; public IntPtr th32DefaultHeapID; public int th32ModuleID;
            public int cntThreads; public int th32ParentProcessID; public int pcPriClassBase; public int dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
        }
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(int flags, int pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32 e);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32 e);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        public static int FindRootProcess(string name) {
            var parent = new Dictionary<int, int>(); var names = new Dictionary<int, string>();
            IntPtr snap = CreateToolhelp32Snapshot(2, 0);
            if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return 0;
            try {
                var e = new PROCESSENTRY32(); e.dwSize = Marshal.SizeOf(typeof(PROCESSENTRY32));
                if (Process32FirstW(snap, ref e)) do { parent[e.th32ProcessID] = e.th32ParentProcessID; names[e.th32ProcessID] = e.szExeFile; } while (Process32NextW(snap, ref e));
            } finally { CloseHandle(snap); }
            string exe = name.ToLowerInvariant() + ".exe";
            foreach (var kv in names) {
                if (kv.Value.ToLowerInvariant() != exe) continue;
                string pn; int pp = parent[kv.Key];
                if (!names.TryGetValue(pp, out pn) || pn.ToLowerInvariant() != exe) return kv.Key;
            }
            return 0;
        }

        // ---------- Audio ----------
        static IntPtr MakeFormat() {
            // 16 Bit PCM, 48 kHz, Stereo - Windows rechnet alles automatisch um (AUTOCONVERTPCM)
            IntPtr f = Marshal.AllocHGlobal(18);
            Marshal.WriteInt16(f, 0, 1); Marshal.WriteInt16(f, 2, Channels); Marshal.WriteInt32(f, 4, Rate);
            Marshal.WriteInt32(f, 8, Rate * Channels * 2); Marshal.WriteInt16(f, 12, Channels * 2);
            Marshal.WriteInt16(f, 14, 16); Marshal.WriteInt16(f, 16, 0);
            return f;
        }
        static void Check(int hr, string what) { if (hr != 0) throw new Exception(what + " (0x" + hr.ToString("X8") + ")"); }

        static IAudioClient OpenDevice(IMMDeviceEnumerator en, string id, int flow, out string name) {
            IMMDevice dev = null;
            if (!string.IsNullOrEmpty(id)) en.GetDevice(id, out dev);
            if (dev == null) Check(en.GetDefaultAudioEndpoint(flow, flow == 1 ? 2 : 0, out dev), "Standardgeraet");
            name = GetName(dev);
            object o; var iid = IID_IAudioClient;
            Check(dev.Activate(ref iid, 23, IntPtr.Zero, out o), "Geraet oeffnen");
            Marshal.ReleaseComObject(dev);
            return (IAudioClient)o;
        }

        static IAudioClient OpenProcessLoopback(int pid, AutoResetEvent ev) {
            // AUDIOCLIENT_ACTIVATION_PARAMS { Typ = Process Loopback, Prozess-ID, Kindprozesse einschliessen }
            IntPtr prm = Marshal.AllocHGlobal(12);
            IntPtr pv = Marshal.AllocHGlobal(8 + 2 * IntPtr.Size);
            try {
                Marshal.WriteInt32(prm, 0, 1); Marshal.WriteInt32(prm, 4, pid); Marshal.WriteInt32(prm, 8, 0);
                for (int i = 0; i < 8 + 2 * IntPtr.Size; i++) Marshal.WriteByte(pv, i, 0);
                Marshal.WriteInt16(pv, 0, 65);              // VT_BLOB
                Marshal.WriteInt32(pv, 8, 12);              // Groesse
                Marshal.WriteIntPtr(pv, 8 + IntPtr.Size, prm);
                var h = new ActivationHandler();
                IActivateAudioInterfaceAsyncOperation op;
                ActivateAudioInterfaceAsync("VAD\\Process_Loopback", IID_IAudioClient, pv, h, out op);
                if (!h.Done.WaitOne(5000)) throw new Exception("Spotify-Ton: keine Antwort");
                Check(h.Result, "Spotify-Ton abgreifen");
                var client = (IAudioClient)h.Client;
                IntPtr fmt = MakeFormat();
                try { Check(client.Initialize(0, LOOPBACK | EVENTCALLBACK | AUTOCONVERT | SRC_QUALITY, 2000000, 0, fmt, IntPtr.Zero), "Spotify-Ton starten"); }
                finally { Marshal.FreeHGlobal(fmt); }
                Check(client.SetEventHandle(ev.SafeWaitHandle.DangerousGetHandle()), "Spotify-Ton Ereignis");
                return client;
            } finally { Marshal.FreeHGlobal(prm); Marshal.FreeHGlobal(pv); }
        }

        static void InitShared(IAudioClient c, long duration, string what) {
            IntPtr fmt = MakeFormat();
            try { Check(c.Initialize(0, AUTOCONVERT | SRC_QUALITY, duration, 0, fmt, IntPtr.Zero), what); }
            finally { Marshal.FreeHGlobal(fmt); }
        }

        static float Drain(IAudioCaptureClient cap, SampleQueue q) {
            float peak = 0; uint packet;
            while (cap.GetNextPacketSize(out packet) == 0 && packet > 0) {
                IntPtr data; uint frames, flags; ulong a, b;
                if (cap.GetBuffer(out data, out frames, out flags, out a, out b) != 0) break;
                int n = (int)frames * Channels;
                bool silent = (flags & 2) != 0;
                for (int i = 0; i < n; i++) {
                    float s = silent ? 0f : Marshal.ReadInt16(data, i * 2) / 32768f;
                    q.Push(s);
                    float abs = s < 0 ? -s : s; if (abs > peak) peak = abs;
                }
                cap.ReleaseBuffer(frames);
            }
            return peak;
        }

        static float SoftClip(float x) {
            float a = x < 0 ? -x : x;
            if (a <= 0.8f) return x;
            float y = 0.8f + 0.2f * (float)Math.Tanh((a - 0.8f) / 0.2f);
            return x < 0 ? -y : y;
        }

        static void Run() {
            while (running) {
                try { Session(); }
                catch (Exception e) { Error = e.Message; Status = "error"; }
                MusicAttached = false;
                for (int i = 0; i < 20 && running && !Restart; i++) Thread.Sleep(100);   // kurz warten, dann neu versuchen
                Restart = false;
            }
        }

        static void Session() {
            var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            IAudioClient outClient = null, micClient = null, musicClient = null;
            IAudioRenderClient render = null; IAudioCaptureClient mic = null, music = null;
            var musicEvent = new AutoResetEvent(false);
            try {
                // 1) Ziel: virtuelles Kabel
                // Nur echte virtuelle Kabel zulassen - sonst landet alles in deinen eigenen Kopfhoerern
                string cableId = CableId;
                if (!string.IsNullOrEmpty(cableId)) {
                    bool ok = false;
                    foreach (var d in GetDevices(0)) { var p = d.Split('	'); if (p[0] == cableId && IsCableName(p[1])) ok = true; }
                    if (!ok) cableId = "";
                }
                if (string.IsNullOrEmpty(cableId)) {
                    var c = FindCable();
                    if (c == null) { Status = "nocable"; CableName = ""; return; }
                    cableId = c.Split('\t')[0];
                }
                string name;
                outClient = OpenDevice(en, cableId, 0, out name); CableName = name;
                InitShared(outClient, 1000000, "Kabel starten");
                uint outFrames; outClient.GetBufferSize(out outFrames);
                object o; var iid = IID_Render;
                Check(outClient.GetService(ref iid, out o), "Kabel"); render = (IAudioRenderClient)o;

                // 2) Dein Mikrofon
                if (UseVoice) {
                    try {
                        micClient = OpenDevice(en, MicId, 1, out name); MicName = name;
                        if (IsCableName(name) || name.ToLowerInvariant().Contains("cable output")) throw new Exception("Als Mikrofon ist das Kabel selbst gewaehlt");
                        InitShared(micClient, 2000000, "Mikrofon starten");
                        iid = IID_Capture; Check(micClient.GetService(ref iid, out o), "Mikrofon"); mic = (IAudioCaptureClient)o;
                        micClient.Start();
                    } catch (Exception e) { Error = "Mikrofon: " + e.Message; if (micClient != null) Marshal.ReleaseComObject(micClient); micClient = null; mic = null; }
                }
                bool voiceWanted = UseVoice; string micWanted = MicId, cableWanted = CableId;

                outClient.Start();
                Status = "ok"; if (mic != null || !UseVoice) Error = "";

                var musicQ = new SampleQueue(Rate * Channels);
                var voiceQ = new SampleQueue(Rate * Channels);
                int pid = 0; DateTime nextAttach = DateTime.MinValue, nextPidCheck = DateTime.MinValue;
                double musicMs = -1;                 // gleitender Mittelwert der Musik-Leistung (fuers Angleichen)
                float normGain = 1f, duckGain = 1f, voiceEnv = 0f;
                // Rauschsperre: Huellkurve, mitlaufender Grundrausch-Pegel, Haltezeit, weiche Blende
                float env = 0f, floor = 0.005f, gateGain = 0f; int hold = 0;
                float[] hpX = new float[2], hpY = new float[2];
                const float HpA = 0.9884f;           // Hochpass ~90 Hz gegen Brummen/Trittschall
                const int HoldFrames = Rate / 4;     // 250 ms offen lassen, damit Wortenden nicht abgeschnitten werden
                const int target = Rate * 30 / 1000; // ~30 ms im Kabel vorhalten
                const int prime = Rate * Channels * 25 / 1000, maxQ = Rate * Channels * 120 / 1000;

                while (running && !Restart) {
                    if (UseVoice != voiceWanted || MicId != micWanted || CableId != cableWanted) return;   // neu aufbauen

                    // Spotify finden bzw. neu verbinden, wenn es neu gestartet wurde
                    DateTime now = DateTime.Now;
                    if (music != null && now >= nextPidCheck) {
                        nextPidCheck = now.AddSeconds(2);
                        bool alive = false; try { alive = !Process.GetProcessById(pid).HasExited; } catch { }
                        if (!alive) { try { musicClient.Stop(); } catch { } Marshal.ReleaseComObject(music); Marshal.ReleaseComObject(musicClient); music = null; musicClient = null; MusicAttached = false; musicQ.Clear(); }
                    }
                    if (music == null && now >= nextAttach) {
                        nextAttach = now.AddSeconds(3);
                        pid = FindRootProcess(ProcessName);
                        if (pid != 0) {
                            try {
                                musicClient = OpenProcessLoopback(pid, musicEvent);
                                iid = IID_Capture; Check(musicClient.GetService(ref iid, out o), "Spotify-Ton"); music = (IAudioCaptureClient)o;
                                musicClient.Start(); MusicAttached = true;
                            } catch (Exception e) { Error = e.Message; if (musicClient != null) Marshal.ReleaseComObject(musicClient); musicClient = null; music = null; }
                        }
                    }

                    float mPeak = music != null ? Drain(music, musicQ) : 0f;
                    float vPeak = mic != null ? Drain(mic, voiceQ) : 0f;
                    // Zu viel gepuffert (Uhren laufen minimal auseinander) -> Aeltestes verwerfen, damit nichts verzoegert
                    if (musicQ.Count > maxQ) musicQ.Drop(musicQ.Count - prime);
                    if (voiceQ.Count > maxQ) voiceQ.Drop(voiceQ.Count - prime);
                    if (!musicQ.Primed && musicQ.Count >= prime) musicQ.Primed = true;
                    if (!voiceQ.Primed && voiceQ.Count >= prime) voiceQ.Primed = true;

                    uint padding; outClient.GetCurrentPadding(out padding);
                    int frames = target - (int)padding;
                    if (frames > 0) {
                        IntPtr buf;
                        if (render.GetBuffer((uint)frames, out buf) == 0) {
                            float mv = MusicVolume, vv = VoiceVolume;
                            bool norm = Normalize, duck = Duck;
                            float gate = GateStrength;
                            float ratio = 2f + 6f * gate, minAbs = 0.001f + 0.012f * gate;
                            double sumSq = 0; float oPeak = 0, vPeakOut = 0; double voiceSq = 0;
                            for (int i = 0; i < frames * Channels; i++) {
                                float m = musicQ.Primed ? musicQ.Pop() : 0f;
                                float v = voiceQ.Primed ? voiceQ.Pop() : 0f;
                                int ch = i & 1;
                                float hp = HpA * (hpY[ch] + v - hpX[ch]); hpX[ch] = v; hpY[ch] = hp; v = hp;
                                if (ch == 0) {
                                    float va0 = v < 0 ? -v : v;
                                    env = va0 > env ? env + (va0 - env) * 0.2f : env * 0.9995f;
                                    // Grundrauschen: faellt schnell mit, steigt nur sehr langsam (Sprechen hebt es kaum an)
                                    floor = env < floor ? floor + (env - floor) * 0.01f : floor + (env - floor) * 0.000005f;
                                    if (floor < 0.0002f) floor = 0.0002f;
                                    if (env > Math.Max(floor * ratio, minAbs)) hold = HoldFrames; else if (hold > 0) hold--;
                                    float gt = (gate <= 0f || hold > 0) ? 1f : 0f;
                                    gateGain += (gt - gateGain) * (gt > gateGain ? 0.01f : 0.0004f);
                                }
                                v *= gateGain;
                                float va = v < 0 ? -v : v; if (va > vPeakOut) vPeakOut = va;
                                sumSq += m * m; voiceSq += v * v;
                                float s = SoftClip(m * mv * normGain * duckGain + v * vv);
                                Marshal.WriteInt16(buf, i * 2, (short)(s * 32767f));
                                float a = s < 0 ? -s : s; if (a > oPeak) oPeak = a;
                            }
                            render.ReleaseBuffer((uint)frames, 0);
                            if (musicQ.Count == 0) musicQ.Primed = false;
                            if (voiceQ.Count == 0) voiceQ.Primed = false;

                            // Lautstaerke angleichen: Ziel ca. -18 dBFS, ueber ein paar Sekunden gemittelt, Stille zaehlt nicht.
                            // Bis 20x, damit es auch klappt, wenn Spotify selbst leise gestellt ist (du hoerst leise, andere normal).
                            double blockMs = sumSq / (frames * Channels);
                            if (blockMs > 1e-8) { if (musicMs < 0) musicMs = blockMs; else { double k = Math.Min(1.0, frames / (Rate * 2.0)); musicMs = musicMs * (1 - k) + blockMs * k; } }
                            float want = norm && musicMs > 0 ? (float)Math.Max(0.5, Math.Min(20.0, 0.12 / Math.Sqrt(musicMs))) : 1f;
                            normGain += (want - normGain) * Math.Min(1f, frames / (Rate * (want > normGain ? 0.8f : 0.3f)));   // runter schneller als rauf

                            // Ducking: sprichst du, wird die Musik schnell leiser und danach langsam wieder lauter
                            float vRms = (float)Math.Sqrt(voiceSq / (frames * Channels)) * vv;
                            voiceEnv = vRms > voiceEnv ? vRms : voiceEnv * 0.97f;
                            float duckWant = duck && voiceEnv > 0.03f ? 0.35f : 1f;
                            duckGain += (duckWant - duckGain) * (duckWant < duckGain ? 0.35f : 0.04f);

                            OutLevel = Math.Max(oPeak, OutLevel * 0.85f);
                            VoiceLevel = Math.Max(vPeakOut, VoiceLevel * 0.85f);
                            VoiceOpen = hold > 0;
                        }
                    }
                    MusicLevel = Math.Max(mPeak, MusicLevel * 0.85f);
                    musicEvent.WaitOne(5);
                }
            } finally {
                Status = running ? Status : "off";
                try { if (outClient != null) outClient.Stop(); } catch { }
                try { if (micClient != null) micClient.Stop(); } catch { }
                try { if (musicClient != null) musicClient.Stop(); } catch { }
                foreach (object c in new object[] { render, mic, music, outClient, micClient, musicClient, en })
                    if (c != null) try { Marshal.ReleaseComObject(c); } catch { }
                musicEvent.Dispose();
                MusicAttached = false;
            }
        }
    }
}
