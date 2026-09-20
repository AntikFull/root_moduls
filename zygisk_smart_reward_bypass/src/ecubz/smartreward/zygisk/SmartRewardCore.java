package ecubz.smartreward.zygisk;

import android.app.Activity;
import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Имитатор инициализации и загрузки рекламы Smart Reward & Fake Ad Loader Engine.
 * 
 * Полная независимость от блокировщиков рекламы (AdAway / Hosts / DNS):
 * 1. Подавление ошибок сети (Suppress Load Failure):
 *    - Перехват OnRewardedAdLoadFailedEvent в AppLovin MAX и автоматическая замена на OnRewardedAdLoadedEvent.
 *    - Подавление onAdFailedToLoad в Google Mobile Ads, Unity Ads, IronSource.
 * 2. Виртуализация State Machine при показе:
 *    - Замена OnRewardedAdFailedToDisplayEvent на полную цепочку: Displayed -> ReceivedReward -> Hidden -> Loaded.
 * 3. FastPass: Мгновенное закрытие экранов показа рекламы и выдача наград.
 * 
 * Автор: eCubz (https://t.me/eCubz)
 */
public final class SmartRewardCore {
    private static final String TAG = "SmartReward-Java";
    public static final String VERSION = "v4.3.1";
    public static final int VERSION_CODE = 431;
    private static volatile boolean sInitialized = false;
    private static volatile Application sApplication = null;
    private static final Handler sMainHandler = new Handler(Looper.getMainLooper());
    private static Boolean sHostsBlocked = null;

    // JNI Native мост к C++ ядру и машине состояний RewardTraceManager
    public static native void nativeNotifyUnityReward(String gameObject, String method, String message);
    public static native long nativeStartRewardTrace(String pkg, String proc, String engine, String sdk, String placement, int confidence);
    public static native void nativeRecordRewardStage(long traceId, int stage, int failure, String detail);
    public static native void nativeRecordReadyCheck(String sdk, String format, String placement, String className, String methodName, boolean value, int reason);

    // RewardStage константы
    public static final int STAGE_PROCESS_DETECTED = 0;
    public static final int STAGE_ENGINE_DETECTED = 1;
    public static final int STAGE_RUNTIME_READY = 2;
    public static final int STAGE_SDK_DETECTED = 3;
    public static final int STAGE_REWARD_OBJECT_FOUND = 4;
    public static final int STAGE_PLACEMENT_RESOLVED = 5;
    public static final int STAGE_SHOW_OBSERVED = 6;
    public static final int STAGE_LISTENER_RESOLVED = 7;
    public static final int STAGE_AD_DISPLAYED = 8;
    public static final int STAGE_COMPLETION_OBSERVED = 9;
    public static final int STAGE_REWARD_CALLBACK_OBSERVED = 10;
    public static final int STAGE_APP_HANDLER_OBSERVED = 11;
    public static final int STAGE_FINISHED = 12;

    // RewardFailure константы
    public static final int FAIL_NONE = 0;
    public static final int FAIL_UNSUPPORTED_ENGINE = 1;
    public static final int FAIL_RUNTIME_NOT_LOADED = 2;
    public static final int FAIL_SDK_NOT_DETECTED = 4;
    public static final int FAIL_REWARD_OBJECT_NOT_FOUND = 7;
    public static final int FAIL_METHOD_NOT_FOUND = 8;
    public static final int FAIL_SIGNATURE_MISMATCH = 9;
    public static final int FAIL_LISTENER_NOT_FOUND = 11;
    public static final int FAIL_SHOW_NOT_OBSERVED = 13;
    public static final int FAIL_DISPLAY_CALLBACK_MISSING = 14;
    public static final int FAIL_COMPLETION_CALLBACK_MISSING = 15;
    public static final int FAIL_REWARD_CALLBACK_MISSING = 16;
    public static final int FAIL_APP_HANDLER_MISSING = 17;

    // NotReadyReason константы
    public static final int NOT_READY_UNKNOWN = 0;
    public static final int NOT_READY_NOT_LOADED = 1;
    public static final int NOT_READY_LOAD_NOT_STARTED = 2;
    public static final int NOT_READY_LOAD_IN_PROGRESS = 3;
    public static final int NOT_READY_LOAD_FAILED = 4;
    public static final int NOT_READY_NO_NETWORK = 5;
    public static final int NOT_READY_NO_FILL = 6;
    public static final int NOT_READY_SDK_NOT_INITIALIZED = 7;
    public static final int NOT_READY_CONSENT_REQUIRED = 8;
    public static final int NOT_READY_COOLDOWN = 10;

    // Захваченные AdUnitId из рантайма
    private static final Set<String> sKnownAdUnitIds = Collections.newSetFromMap(new ConcurrentHashMap<String, Boolean>());
    private static volatile Object sMaxBackgroundCallback = null;
    private static final Object sProfileIoLock = new Object();

    private static String jsonEscape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t");
    }

    /**
     * Append-only advertising observation store.  Facts are explicitly tagged
     * observed/inferred/synthetic so module-generated values never masquerade
     * as values actually returned by the game or SDK.
     */
    private static String normalizeTrust(String trust) {
        if ("observed".equals(trust) || "inferred".equals(trust) || "synthetic".equals(trust)) {
            return trust;
        }
        // Unknown provenance must never be promoted to an observed runtime fact.
        return "inferred";
    }

    private static void recordProfileObservation(String type, String trust, String source,
                                                 String sdk, String format, String identifier,
                                                 String placement, String rewardType,
                                                 String rewardAmount, String detail) {
        Application app = sApplication;
        if (app == null) return;
        try {
            File dir = new File(app.getFilesDir(), "zygisk_smart_reward_bypass");
            if (!dir.exists() && !dir.mkdirs()) return;
            File events = new File(dir, app.getPackageName() + "__events.jsonl");
            String line = "{"
                    + "\"ts_ms\":" + System.currentTimeMillis() + ","
                    + "\"process\":\"" + jsonEscape(getCurrentProcessName()) + "\","
                    + "\"type\":\"" + jsonEscape(type) + "\","
                    + "\"trust\":\"" + jsonEscape(normalizeTrust(trust)) + "\","
                    + "\"source\":\"" + jsonEscape(source) + "\","
                    + "\"sdk\":\"" + jsonEscape(sdk) + "\","
                    + "\"format\":\"" + jsonEscape(format) + "\","
                    + "\"identifier\":\"" + jsonEscape(identifier) + "\","
                    + "\"placement\":\"" + jsonEscape(placement) + "\","
                    + "\"reward_type\":\"" + jsonEscape(rewardType) + "\","
                    + "\"reward_amount\":\"" + jsonEscape(rewardAmount) + "\","
                    + "\"detail\":\"" + jsonEscape(detail) + "\"}\n";
            synchronized (sProfileIoLock) {
                FileOutputStream out = new FileOutputStream(events, true);
                try {
                    out.write(line.getBytes("UTF-8"));
                    out.flush();
                } finally {
                    out.close();
                }
            }
        } catch (Throwable t) {
            Log.d(TAG, "profile observation write note: " + t.getMessage());
        }
    }

    private static void rememberAdUnit(String value, String trust, String source, String sdk, String format) {
        if (value == null) return;
        String v = value.trim();
        if (v.isEmpty()) return;
        sKnownAdUnitIds.add(v);
        recordProfileObservation("ad_identifier", trust, source, sdk, format, v, "", "", "", "");
    }

    private static String extractJsonString(String json, String key) {
        if (json == null || key == null) return "";
        String marker = "\"" + key + "\":\"";
        int start = json.indexOf(marker);
        if (start < 0) return "";
        start += marker.length();
        int end = start;
        boolean escaped = false;
        while (end < json.length()) {
            char c = json.charAt(end);
            if (c == '\"' && !escaped) break;
            escaped = (c == '\\' && !escaped);
            if (c != '\\') escaped = false;
            end++;
        }
        return end > start ? json.substring(start, end) : "";
    }

    private static String extractJsonNumber(String json, String key) {
        if (json == null || key == null) return "";
        String marker = "\"" + key + "\":";
        int start = json.indexOf(marker);
        if (start < 0) return "";
        start += marker.length();
        while (start < json.length() && Character.isWhitespace(json.charAt(start))) start++;
        int end = start;
        while (end < json.length()) {
            char c = json.charAt(end);
            if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') end++;
            else break;
        }
        return end > start ? json.substring(start, end) : "";
    }

    private static void observeSdkPayload(String json, String source) {
        if (json == null || json.isEmpty()) return;
        String sdk = extractJsonString(json, "networkName");
        if (sdk.isEmpty()) sdk = "AppLovin";
        String format = extractJsonString(json, "adFormat");
        String unit = extractJsonString(json, "adUnitId");
        if (unit.isEmpty()) unit = extractJsonString(json, "adUnitIdentifier");
        String placement = extractJsonString(json, "placement");
        if (placement.isEmpty()) placement = extractJsonString(json, "networkPlacement");
        String rewardType = extractJsonString(json, "rewardLabel");
        if (rewardType.isEmpty()) rewardType = extractJsonString(json, "label");
        String rewardAmount = extractJsonNumber(json, "rewardAmount");
        if (rewardAmount.isEmpty()) rewardAmount = extractJsonNumber(json, "amount");
        String event = extractJsonString(json, "name");
        String creative = extractJsonString(json, "creativeIdentifier");
        String revenue = extractJsonNumber(json, "revenue");

        if (!unit.isEmpty()) {
            rememberAdUnit(unit, "observed", source, sdk, format);
            DynamicAdMeta meta = sDynamicAdMetaMap.get(unit);
            if (meta == null) {
                meta = new DynamicAdMeta();
                meta.adUnitId = unit;
                sDynamicAdMetaMap.put(unit, meta);
            }
            if (!creative.isEmpty()) meta.creativeIdentifier = creative;
            if (!placement.isEmpty()) meta.placement = placement;
            if (!sdk.isEmpty()) meta.networkName = sdk;
            if (!format.isEmpty()) meta.adFormat = format;
            if (!rewardType.isEmpty()) meta.rewardLabel = rewardType;
            if (!rewardAmount.isEmpty()) {
                try { meta.rewardAmount = Double.parseDouble(rewardAmount); } catch (Throwable ignored) { /* глушение-обосновано: парсинг опционального числа */ }
            }
            if (!revenue.isEmpty()) {
                try { meta.revenue = Double.parseDouble(revenue); } catch (Throwable ignored) { /* глушение-обосновано: парсинг опционального числа */ }
            }
            meta.lastSeenMs = System.currentTimeMillis();
        }
        if (!event.isEmpty() || !placement.isEmpty() || !rewardType.isEmpty() || !rewardAmount.isEmpty()
                || !creative.isEmpty() || !revenue.isEmpty()) {
            String detail = "event=" + event + ";creative=" + creative + ";revenue=" + revenue;
            recordProfileObservation("sdk_callback", "observed", source, sdk, format, unit,
                    placement, rewardType, rewardAmount, detail);
        }
    }

    public static class DynamicAdMeta {
        public String adUnitId = "";
        public String creativeIdentifier = "";
        public String placement = "";
        public String networkPlacement = "";
        public String networkName = "AppLovin";
        public String adFormat = "REWARDED";
        public String rewardLabel = "";
        public double rewardAmount = 0.0;
        public double revenue = 0.0;
        public long lastSeenMs = 0;

        public String getCreativeIdentifier() {
            if (creativeIdentifier != null && !creativeIdentifier.isEmpty()) {
                return creativeIdentifier;
            }
            long seed = System.currentTimeMillis() ^ (adUnitId != null ? (long) adUnitId.hashCode() : 0L);
            return "cr_" + Long.toHexString(seed & 0xFFFFFFFFL);
        }
    }

    private static final Map<String, DynamicAdMeta> sDynamicAdMetaMap = new ConcurrentHashMap<>();


    // Зарегистрированные слушатели наград и лоадеры
    private static final Set<Object> sRegisteredRewardListeners = Collections.synchronizedSet(
            Collections.newSetFromMap(new WeakHashMap<Object, Boolean>()));
    private static final Set<Object> sHandledLoadListeners = Collections.synchronizedSet(
            Collections.newSetFromMap(new WeakHashMap<Object, Boolean>()));
    private static final Set<Object> sHandledInitListeners = Collections.synchronizedSet(
            Collections.newSetFromMap(new WeakHashMap<Object, Boolean>()));
    private static final Set<Activity> sBannerCollapserAttached = Collections.synchronizedSet(
            Collections.newSetFromMap(new WeakHashMap<Activity, Boolean>()));
    // Object-identity cache: two instances of the same class can hold different runtime state.
    private static final Set<Object> sScannedObjects = Collections.synchronizedSet(
            Collections.newSetFromMap(new WeakHashMap<Object, Boolean>()));

    private enum RuntimePhase {
        STARTING, APPLICATION_READY, ACTIVITY_READY, PASSIVE_RUNTIME
    }

    private static volatile RuntimePhase sRuntimePhase = RuntimePhase.STARTING;
    private static final AtomicBoolean sLifecycleRegistered = new AtomicBoolean(false);

    private static void setRuntimePhase(RuntimePhase phase, String reason) {
        RuntimePhase old = sRuntimePhase;
        if (phase.ordinal() > old.ordinal()) {
            sRuntimePhase = phase;
            Log.i(TAG, "[PHASE] " + old + " -> " + phase + " (" + reason + ")");
        }
    }

    // Список известных SDK Activity
    private static final Set<String> STRICT_AD_ACTIVITIES = new HashSet<>(Arrays.asList(
        "com.google.android.gms.ads.AdActivity",
        "com.applovin.adview.AppLovinFullscreenActivity",
        "com.applovin.adview.AppLovinInterstitialActivity",
        "com.facebook.ads.AudienceNetworkActivity",
        "com.facebook.ads.internal.ipc.RemoteANActivity",
        "com.unity3d.services.ads.adunit.AdUnitActivity",
        "com.unity3d.services.ads.adunit.AdUnitSoftwareActivity",
        "com.unity3d.ads.adplayer.FullScreenWebViewDisplay",
        "com.unity3d.ads.adplayer.AndroidFullscreenWebViewDisplay",
        "com.unity3d.ads.adplayer.UnityPlayerActivity",
        "com.yandex.mobile.ads.common.AdActivity",
        "com.ironsource.sdk.controller.ControllerActivity",
        "com.ironsource.sdk.controller.InterstitialActivity",
        "com.ironsource.sdk.controller.OpenUrlActivity",
        "com.vungle.warren.ui.VungleActivity",
        "com.vungle.ads.internal.ui.VungleActivity",
        "com.vungle.ads.internal.ui.AdActivity",
        "com.mbridge.msdk.reward.player.MBRewardVideoActivity",
        "com.mbridge.msdk.activity.MBCommonActivity",
        "com.bytedance.sdk.openadsdk.activity.TTFullScreenVideoActivity",
        "com.bytedance.sdk.openadsdk.activity.TTRewardVideoActivity",
        "com.bytedance.sdk.openadsdk.activity.TTRewardExpressVideoActivity",
        "com.bytedance.sdk.openadsdk.activity.TTAppOpenAdActivity",
        "com.mintegral.msdk.reward.player.MBRewardVideoActivity",
        "com.adcolony.sdk.AdColonyInterstitialActivity",
        "com.adcolony.sdk.AdColonyAdViewActivity",
        "com.chartboost.sdk.view.CBImpressionActivity",
        "com.inmobi.ads.rendering.InMobiAdActivity",
        "com.fyber.inneractive.sdk.activities.InneractiveFullscreenAdActivity",
        "com.fyber.inneractive.sdk.activities.InneractiveRichMediaVideoPlayerActivity",
        "com.my.target.common.MyTargetActivity"
    ));

    // Классы баннеров и нативной рекламы
    private static final Set<String> AD_SURFACE_CLASSES = new HashSet<>(Arrays.asList(
        "com.yandex.mobile.ads.banner.BannerAdView",
        "com.yandex.mobile.ads.banner.AdView",
        "com.yandex.mobile.ads.nativeads.template.NativeBannerView",
        "com.yandex.mobile.ads.nativeads.NativeAdView",
        "com.yandex.mobile.ads.nativeads.MediaView",
        "com.google.android.gms.ads.AdView",
        "com.google.android.gms.ads.BaseAdView",
        "com.google.android.gms.ads.nativead.NativeAdView",
        "com.google.android.gms.ads.nativead.MediaView",
        "com.applovin.mediation.ads.MaxAdView",
        "com.applovin.mediation.nativeAds.MaxNativeAdView",
        "com.unity3d.services.banners.BannerView",
        "com.ironsource.mediationsdk.IronSourceBannerLayout",
        "com.my.target.ads.MyTargetView"
    ));

    public static boolean init(Application application) {
        if (sInitialized) return true;
        if (application == null) return false;
        synchronized (SmartRewardCore.class) {
            if (sInitialized) return true;
            try {
                sApplication = application;
                Log.i(TAG, "Инициализация SmartReward ядра " + VERSION + " (Universal Dynamic Ad Loader) для пакета: " + application.getPackageName());

                // Инициализация синтетических fallback AdUnits (trust: synthetic) для мгновенного старта виртуального вещателя
                rememberAdUnit("default_rewarded", "synthetic", "fallback_init", "AppLovin", "REWARDED");
                rememberAdUnit("rewarded_video", "synthetic", "fallback_init", "UnityAds", "REWARDED");
                rememberAdUnit("rewarded_ad", "synthetic", "fallback_init", "Google Mobile Ads", "REWARDED");

                registerLifecycleCallbacks(application);
                schedulePluginHooks();
                performInitialReadinessCheck();
                setRuntimePhase(RuntimePhase.APPLICATION_READY, "Application initialized");

                sInitialized = true;
                Log.i(TAG, "SmartReward " + VERSION + " успешно запущен!");
                return true;
            } catch (Throwable t) {
                Log.e(TAG, "Ошибка при запуске SmartRewardCore: " + t.getMessage(), t);
                return false;
            }
        }
    }

    private static ClassLoader getAppClassLoader() {
        if (sApplication != null) {
            return sApplication.getClassLoader();
        }
        return Thread.currentThread().getContextClassLoader();
    }

    private static final AtomicBoolean sInitialCheckDone = new AtomicBoolean(false);
    private static final Runnable sReplenishmentRunnable = new Runnable() {
        @Override
        public void run() {
            try {
                if (sApplication != null) {
                    if (!sMaxHooked.get()) {
                        if (hookAppLovinMaxPlugin()) {
                            sMaxHooked.set(true);
                            Log.i(TAG, "[HOOKS_INIT] AppLovin MAX plugin hooked via replenishment worker!");
                        }
                    }
                    broadcastFakeInitAndLoadedState();
                }
            } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
            if (sMainHandler != null) {
                sMainHandler.postDelayed(this, 2500);
            }
        }
    };

    /**
     * Реактивная инициализация готовности рекламы (Multi-SDK Reactive Readiness Check)
     * Выполняется при старте приложения и активации Activity без бесконечных циклов
     */
    private static void performInitialReadinessCheck() {
        if (sInitialCheckDone.compareAndSet(false, true)) {
            sMainHandler.postDelayed(new Runnable() {
                @Override
                public void run() {
                    try {
                        broadcastFakeInitAndLoadedState();
                        scanAndTriggerAdObjects();
                    } catch (Throwable t) {
                        Log.d(TAG, "Initial readiness check note: " + t.getMessage());
                    }
                }
            }, 800);

            // Однократный фоллоу-ап для лениво загружаемых SDK через 2.5 сек
            sMainHandler.postDelayed(new Runnable() {
                @Override
                public void run() {
                    try {
                        broadcastFakeInitAndLoadedState();
                        scanAndTriggerAdObjects();
                    } catch (Throwable t) {
                        Log.d(TAG, "Follow-up readiness check note: " + t.getMessage());
                    }
                }
            }, 2500);

            // Непрерывное пополнение кэша готовых наград для неограниченных повторных кликов
            sMainHandler.postDelayed(sReplenishmentRunnable, 3000);
        }
    }

    private static final AtomicBoolean sMaxHooked = new AtomicBoolean(false);
    private static final AtomicBoolean sGoogleHooked = new AtomicBoolean(false);
    private static final AtomicBoolean sIronHooked = new AtomicBoolean(false);
    private static final AtomicBoolean sUnityHooked = new AtomicBoolean(false);
    private static final AtomicBoolean sYandexHooked = new AtomicBoolean(false);
    private static final AtomicInteger sPluginHookRetries = new AtomicInteger(0);

    /**
     * Упреждающее и безопасное подключение хуков плагинов с независимым отслеживанием каждого SDK
     */
    private static void schedulePluginHooks() {
        if (sPluginHookRetries.getAndIncrement() < 50) {
            sMainHandler.postDelayed(new Runnable() {
                @Override
                public void run() {
                    try {
                        if (!sMaxHooked.get()) {
                            boolean max = hookAppLovinMaxPlugin();
                            if (max) {
                                sMaxHooked.set(true);
                                Log.i(TAG, "[HOOKS_INIT] AppLovin MAX plugin successfully hooked!");
                            }
                        }
                        if (!sGoogleHooked.get()) {
                            boolean google = hookGoogleMobileAdsPlugin();
                            if (google) {
                                sGoogleHooked.set(true);
                                Log.i(TAG, "[HOOKS_INIT] Google Mobile Ads plugin successfully hooked!");
                            }
                        }
                        if (!sIronHooked.get()) {
                            boolean iron = hookIronSourcePlugin();
                            if (iron) {
                                sIronHooked.set(true);
                                Log.i(TAG, "[HOOKS_INIT] IronSource plugin successfully hooked!");
                            }
                        }
                        if (!sUnityHooked.get()) {
                            boolean unity = hookUnityAdsPlugin();
                            if (unity) {
                                sUnityHooked.set(true);
                                Log.i(TAG, "[HOOKS_INIT] UnityAds plugin successfully hooked!");
                            }
                        }
                        if (!sYandexHooked.get()) {
                            boolean yandex = hookYandexAdsPlugin();
                            if (yandex) {
                                sYandexHooked.set(true);
                                Log.i(TAG, "[HOOKS_INIT] Yandex Ads plugin successfully hooked!");
                            }
                        }
                        if ((!sMaxHooked.get() || !sGoogleHooked.get()) && sPluginHookRetries.get() < 50) {
                            schedulePluginHooks();
                        }
                    } catch (Throwable t) {
                        Log.d(TAG, "Plugin hook scheduling note: " + t.getMessage());
                    }
                }
            }, 300);
        }
    }

    /**
     * Обнаружение блокировки рекламы через файл hosts (0.0.0.0 / 127.0.0.1) с фильтрацией по конкретному SDK
     */
    public static boolean isSdkHostsBlocked(String sdkName) {
        try {
            File[] hostFiles = new File[]{
                new File("/system/etc/hosts"),
                new File("/data/adb/hosts"),
                new File("/etc/hosts")
            };
            List<String> patterns = new ArrayList<>();
            if (sdkName != null) {
                String s = sdkName.toLowerCase();
                if (s.contains("applovin") || s.contains("max")) {
                    patterns.add("applovin.com");
                    patterns.add("applvn.com");
                } else if (s.contains("admob") || s.contains("google")) {
                    patterns.add("googleads.g.doubleclick.net");
                    patterns.add("pagead2.googlesyndication.com");
                    patterns.add("admob.com");
                } else if (s.contains("unity")) {
                    patterns.add("unityads.unity3d.com");
                    patterns.add("auction.unityads.unity3d.com");
                } else if (s.contains("ironsource")) {
                    patterns.add("ironsrc.mobi");
                    patterns.add("ironsource.com");
                } else if (s.contains("yandex")) {
                    patterns.add("ads.yandex.ru");
                    patterns.add("mobile.yandex.net");
                    patterns.add("yandex.net");
                    patterns.add("an.yandex.ru");
                }
            }
            if (patterns.isEmpty()) {
                patterns.addAll(Arrays.asList("applovin.com", "googleads", "admob", "unityads", "ironsource", "yandex"));
            }

            for (File hf : hostFiles) {
                if (hf.exists() && hf.canRead()) {
                    BufferedReader br = new BufferedReader(new FileReader(hf));
                    String line;
                    while ((line = br.readLine()) != null) {
                        String trim = line.trim().toLowerCase();
                        if (trim.startsWith("#") || trim.isEmpty()) continue;

                        boolean isLoopback = (trim.startsWith("0.0.0.0") && trim.length() > 7 && (trim.charAt(7) == ' ' || trim.charAt(7) == '\t')) ||
                                             (trim.startsWith("127.0.0.1") && trim.length() > 9 && (trim.charAt(9) == ' ' || trim.charAt(9) == '\t'));
                        if (isLoopback) {
                            for (String pat : patterns) {
                                if (trim.contains(pat)) {
                                    br.close();
                                    Log.i(TAG, "[HOSTS_PROBE] Hosts block detected for SDK '" + sdkName + "' (" + pat + ") in " + hf.getAbsolutePath());
                                    return true;
                                }
                            }
                        }
                    }
                    br.close();
                }
            }
        } catch (Throwable t) {
            Log.d(TAG, "Hosts check note: " + t.getMessage());
        }
        return false;
    }

    public static boolean isHostsBlocked() {
        if (sHostsBlocked != null) return sHostsBlocked;
        sHostsBlocked = isSdkHostsBlocked(null);
        return sHostsBlocked;
    }

    private static String getCurrentProcessName() {
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                return Application.getProcessName();
            } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
        }
        try {
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Method currentProcessName = activityThread.getDeclaredMethod("currentProcessName");
            Object name = currentProcessName.invoke(null);
            if (name instanceof String) {
                return (String) name;
            }
        } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
        return sApplication != null ? sApplication.getPackageName() : "main";
    }

    /**
     * Последовательная отправка 4-шаговой цепочки наград AppLovin MAX
     */
    private static void emitMaxRewardedSequence(Object callbackObject, String adUnitId) {
        long traceId = 0;
        String u = (adUnitId != null && !adUnitId.isEmpty()) ? adUnitId : (!sKnownAdUnitIds.isEmpty() ? sKnownAdUnitIds.iterator().next() : "");
        if (!u.isEmpty()) {
            rememberAdUnit(u, "synthetic", "emitMaxRewardedSequence", "AppLovin", "REWARDED");
        }

        try {
            String pkg = sApplication != null ? sApplication.getPackageName() : "unknown";
            String proc = getCurrentProcessName();
            traceId = nativeStartRewardTrace(pkg, proc, "Java/MaxUnityPlugin", "AppLovin", u, 100);
            nativeRecordRewardStage(traceId, STAGE_SHOW_OBSERVED, FAIL_NONE, "AppLovin MAX virtual reward initiated");
        } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }

        DynamicAdMeta meta = sDynamicAdMetaMap.get(u);
        String creativeId = (meta != null) ? meta.getCreativeIdentifier() : ("cr_" + Long.toHexString((System.currentTimeMillis() ^ (long) u.hashCode()) & 0xFFFFFFFFL));
        String netPlacement = (meta != null && !meta.networkPlacement.isEmpty()) ? meta.networkPlacement : "";
        String placement = meta != null ? meta.placement : "";
        String netName = (meta != null && !meta.networkName.isEmpty()) ? meta.networkName : "AppLovin";
        String rLabel = (meta != null && !meta.rewardLabel.isEmpty()) ? meta.rewardLabel : "";
        double rAmt = (meta != null && meta.rewardAmount > 0) ? meta.rewardAmount : 1.0;
        double rev = (meta != null && meta.revenue > 0) ? meta.revenue : 0.05;

        String loaded = "{\"name\":\"OnRewardedAdLoadedEvent\",\"adUnitId\":\"" + u + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + u + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";
        String disp = "{\"name\":\"OnRewardedAdDisplayedEvent\",\"adUnitId\":\"" + u + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + u + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\"}}";
        String rwd = "{\"name\":\"OnRewardedAdReceivedRewardEvent\",\"adUnitId\":\"" + u + "\",\"rewardLabel\":\"" + rLabel + "\",\"rewardAmount\":" + rAmt + ",\"reward\":{\"label\":\"" + rLabel + "\",\"amount\":" + rAmt + "},\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + u + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";
        String hid = "{\"name\":\"OnRewardedAdHiddenEvent\",\"adUnitId\":\"" + u + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + u + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\"}}";
        String rwdInter = "{\"name\":\"OnRewardedInterstitialAdReceivedRewardEvent\",\"adUnitId\":\"" + u + "\",\"rewardLabel\":\"" + rLabel + "\",\"rewardAmount\":" + rAmt + ",\"reward\":{\"label\":\"" + rLabel + "\",\"amount\":" + rAmt + "},\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + u + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";
        String hidInter = "{\"name\":\"OnRewardedInterstitialAdHiddenEvent\",\"adUnitId\":\"" + u + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + u + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\"}}";

        // 1. Фаза 1: Загрузка -> Показ -> Получение награды (Мгновенно)
        if (callbackObject != null) {
            try {
                Method targetMethod = null;
                for (Method cbMethod : callbackObject.getClass().getDeclaredMethods()) {
                    if (cbMethod.getParameterTypes().length == 1 && cbMethod.getParameterTypes()[0] == String.class) {
                        String mName = cbMethod.getName().toLowerCase();
                        if (mName.contains("callback") || mName.contains("forward") || mName.contains("event") || mName.contains("on")) {
                            targetMethod = cbMethod;
                            break;
                        }
                        if (targetMethod == null) {
                            targetMethod = cbMethod;
                        }
                    }
                }
                if (targetMethod != null) {
                    targetMethod.setAccessible(true);
                    targetMethod.invoke(callbackObject, loaded);
                    if (traceId != 0) nativeRecordRewardStage(traceId, STAGE_PLACEMENT_RESOLVED, FAIL_NONE, "OnRewardedAdLoadedEvent");

                    targetMethod.invoke(callbackObject, disp);
                    if (traceId != 0) nativeRecordRewardStage(traceId, STAGE_AD_DISPLAYED, FAIL_NONE, "OnRewardedAdDisplayedEvent");

                    targetMethod.invoke(callbackObject, rwd);
                    targetMethod.invoke(callbackObject, rwdInter);
                    if (traceId != 0) nativeRecordRewardStage(traceId, STAGE_REWARD_CALLBACK_OBSERVED, FAIL_NONE, "OnRewardedAdReceivedRewardEvent");

                    final Method finalMethod = targetMethod;
                    final Object finalCb = callbackObject;
                    final long finalTraceId = traceId;

                    // Фаза 2: Закрытие рекламы через 80 мс (после гарантированного установления флага награды в C#)
                    sMainHandler.postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            try {
                                finalMethod.invoke(finalCb, hid);
                                finalMethod.invoke(finalCb, hidInter);
                                if (finalTraceId != 0) nativeRecordRewardStage(finalTraceId, STAGE_COMPLETION_OBSERVED, FAIL_NONE, "OnRewardedAdHiddenEvent");

                                finalMethod.invoke(finalCb, loaded);
                                if (finalTraceId != 0) nativeRecordRewardStage(finalTraceId, STAGE_FINISHED, FAIL_NONE, "OnRewardedAdLoadedEvent (cycle complete)");
                            } catch (Throwable t) {
                                Log.d(TAG, "Proxy Phase 2 note: " + t.getMessage());
                            }
                        }
                    }, 80);

                    Log.i(TAG, "[VIRTUAL_AD] AppLovin MAX reward sequence (Phase 1) emitted via Proxy for " + u);
                }
            } catch (Throwable t) {
                Log.w(TAG, "Error emitting MAX reward sequence via proxy: " + t.getMessage());
            }
        }

        // 2. Параллельная прямая доставка в UnitySendMessage bus
        try {
            ClassLoader cl = getAppClassLoader();
            Class<?> unityPlayer = cl.loadClass("com.unity3d.player.UnityPlayer");
            final Method sendMsg = unityPlayer.getDeclaredMethod("UnitySendMessage", String.class, String.class, String.class);
            sendMsg.setAccessible(true);

            sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", loaded);
            sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", disp);
            sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", rwd);
            sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", rwdInter);

            sendMsg.invoke(null, "MobileAdsHandler", "OnRewardedAdReceivedRewardEvent", rwd);
            sendMsg.invoke(null, "MobileAdsHandler", "OnRewardedInterstitialAdReceivedRewardEvent", rwdInter);
            Log.i(TAG, "[VIRTUAL_AD] AppLovin MAX Phase 1 (Reward) broadcasted via UnitySendMessage for " + u);

            // Фаза 2 UnitySendMessage: Закрытие рекламы через 80 мс
            sMainHandler.postDelayed(new Runnable() {
                @Override
                public void run() {
                    try {
                        sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", hid);
                        sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", hidInter);
                        sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", loaded);

                        sendMsg.invoke(null, "MobileAdsHandler", "OnRewardedAdHiddenEvent", hid);
                        sendMsg.invoke(null, "MobileAdsHandler", "OnRewardedInterstitialAdHiddenEvent", hidInter);
                        Log.i(TAG, "[VIRTUAL_AD] AppLovin MAX Phase 2 (Hidden) broadcasted via UnitySendMessage for " + u);
                    } catch (Throwable t) {
                        Log.d(TAG, "UnitySendMessage Phase 2 note: " + t.getMessage());
                    }
                }
            }, 80);
        } catch (Throwable t) {
            Log.d(TAG, "UnitySendMessage note: " + t.getMessage());
        }
    }

    /**
     * Перехват AppLovin MAX Unity Plugin и замена сетевых ошибок на успешную загрузку и показ
     */
    private static Object createMaxProxyCallback(final Object origCb, ClassLoader cl) {
        if (origCb == null || Proxy.isProxyClass(origCb.getClass())) return origCb;
        Class<?>[] interfaces = origCb.getClass().getInterfaces();
        if (interfaces.length == 0) {
            // Если у класса нет интерфейсов, ищем в суперклассах или интерфейсах по иерархии
            Class<?> curr = origCb.getClass();
            while (curr != null && interfaces.length == 0) {
                interfaces = curr.getInterfaces();
                curr = curr.getSuperclass();
            }
        }
        if (interfaces.length == 0) return origCb;

        sMaxBackgroundCallback = origCb;
        return Proxy.newProxyInstance(
            cl,
            interfaces,
            new InvocationHandler() {
                @Override
                public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
                    if (args != null && args.length == 1 && args[0] instanceof String) {
                        String json = (String) args[0];
                        observeSdkPayload(json, "MaxUnityPlugin.callback");
                        String capturedUnit = "";
                        // Захват adUnitId
                        if (json.contains("\"adUnitId\":\"")) {
                            int start = json.indexOf("\"adUnitId\":\"") + 12;
                            int end = json.indexOf("\"", start);
                            if (start > 11 && end > start) {
                                capturedUnit = json.substring(start, end);
                                rememberAdUnit(capturedUnit, "observed", "MaxUnityPlugin.callback", "AppLovin", "");
                            }
                        }
                        if (capturedUnit.isEmpty() && json.contains("\"adUnitIdentifier\":\"")) {
                            int start = json.indexOf("\"adUnitIdentifier\":\"") + 20;
                            int end = json.indexOf("\"", start);
                            if (start > 19 && end > start) {
                                capturedUnit = json.substring(start, end);
                                rememberAdUnit(capturedUnit, "observed", "MaxUnityPlugin.callback", "AppLovin", "");
                            }
                        }

                        // При сбое показа (FailedToDisplay) -> запускаем полную цепочку выдачи наград
                        if (json.contains("FailedToDisplay") || json.contains("DisplayFailed")) {
                            Log.i(TAG, "[VIRTUAL_AD] Сбой показа AppLovin перехвачен -> запускаем цепочку наград!");
                            emitMaxRewardedSequence(origCb, capturedUnit);
                            return null;
                        }

                        // Подмена ошибок загрузки сети на успешную загрузку
                        boolean isRewardedFail = json.contains("OnRewardedAdLoadFailedEvent");
                        boolean isInterFail = json.contains("OnInterstitialLoadFailedEvent");
                        if (isRewardedFail || isInterFail || json.contains("OnAdLoadFailedEvent") || json.contains("LoadFailed")) {
                            if (isRewardedFail || json.contains("Rewarded")) {
                                json = "{\"name\":\"OnRewardedAdLoadedEvent\",\"adUnitId\":\"" + capturedUnit + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + capturedUnit + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1038386487\",\"revenue\":0.05,\"revenuePrecision\":\"exact\"}}";
                            } else {
                                json = "{\"name\":\"OnInterstitialLoadedEvent\",\"adUnitId\":\"" + capturedUnit + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + capturedUnit + "\",\"adFormat\":\"INTER\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1038386487\",\"revenue\":0.05,\"revenuePrecision\":\"exact\"}}";
                            }
                            args[0] = json;
                            Log.i(TAG, "[FAKE_AD_LOADER] Сетевая ошибка AppLovin заменена на LoadedEvent для: " + capturedUnit);
                        }

                        // При закрытии рекламы -> планируем автоматическую перезагрузку для бесконечных последующих кликов
                        if (json.contains("OnRewardedAdHiddenEvent") || json.contains("OnRewardedInterstitialAdHiddenEvent")) {
                            final String reloadUnit = capturedUnit;
                            sMainHandler.postDelayed(new Runnable() {
                                @Override
                                public void run() {
                                    try {
                                        String reloadJson = "{\"name\":\"OnRewardedAdLoadedEvent\",\"adUnitId\":\"" + reloadUnit + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + reloadUnit + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1038386487\",\"revenue\":0.05,\"revenuePrecision\":\"exact\"}}";
                                        for (Method m : origCb.getClass().getDeclaredMethods()) {
                                            if (m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == String.class) {
                                                m.setAccessible(true);
                                                m.invoke(origCb, reloadJson);
                                                break;
                                            }
                                        }
                                    } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
                                }
                            }, 300);
                        }
                    }
                    return method.invoke(origCb, args);
                }
            }
        );
    }

    private static boolean hookAppLovinMaxPlugin() {
        boolean hooked = false;
        try {
            ClassLoader cl = getAppClassLoader();
            String[] targetClasses = new String[]{
                "com.applovin.mediation.unity.MaxUnityAdManager",
                "com.applovin.mediation.unity.MaxUnityPlugin",
                "com.applovin.mediation.unity.Utils"
            };

            for (String clsName : targetClasses) {
                Class<?> cls = null;
                try {
                    cls = cl.loadClass(clsName);
                } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
                if (cls == null) continue;
                recordProfileObservation("sdk_class", "observed", "classloader", "AppLovin MAX", "", "", "", "", "", clsName);

                // Получение инстанса синглтона MaxUnityAdManager при наличии
                Object instance = null;
                try {
                    Method getInstance = cls.getDeclaredMethod("getInstance");
                    getInstance.setAccessible(true);
                    instance = getInstance.invoke(null);
                } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }

                for (Field f : cls.getDeclaredFields()) {
                    if (!f.getType().isPrimitive() && f.getType() != String.class) {
                        String fName = f.getName().toLowerCase();
                        String typeName = f.getType().getSimpleName().toLowerCase();
                        boolean isCallbackField = fName.contains("callback") || fName.contains("listener") || fName.contains("handler") ||
                                                  fName.contains("background") || typeName.contains("callback") || typeName.contains("listener") ||
                                                  typeName.contains("handler") || typeName.contains("proxy");
                        if (!isCallbackField) continue;

                        try {
                            f.setAccessible(true);
                            Object targetObj = Modifier.isStatic(f.getModifiers()) ? null : instance;
                            if (targetObj == null && !Modifier.isStatic(f.getModifiers())) continue;

                            final Object origCb = f.get(targetObj);
                            if (origCb != null && !Proxy.isProxyClass(origCb.getClass())) {
                                Object proxyCb = createMaxProxyCallback(origCb, cl);
                                if (proxyCb != origCb) {
                                    f.set(targetObj, proxyCb);
                                    hooked = true;
                                    Log.i(TAG, "[FAKE_AD_LOADER] AppLovin MAX Callback (" + cls.getSimpleName() + "." + f.getName() + ") успешно перехвачен и защищен");
                                }
                            }
                        } catch (Throwable t) {
                            Log.d(TAG, "Field " + f.getName() + " hook note: " + t.getMessage());
                        }
                    }
                }
            }
        } catch (Throwable t) {
            Log.d(TAG, "MaxUnityPlugin hook note: " + t.getMessage());
        }
        return hooked;
    }

    private static boolean hookGoogleMobileAdsPlugin() {
        boolean hooked = false;
        try {
            ClassLoader cl = getAppClassLoader();
            // 1. Поиск и инициализация MobileAds
            try {
                Class<?> mobileAdsCls = cl.loadClass("com.google.android.gms.ads.MobileAds");
                if (mobileAdsCls != null) {
                    hooked = true;
                    recordProfileObservation("sdk_class", "observed", "classloader", "Google Mobile Ads", "CORE", "", "", "", "", mobileAdsCls.getName());

                    // Пытаемся вызвать MobileAds.initialize(sApplication)
                    if (sApplication != null) {
                        try {
                            Method initMethod = mobileAdsCls.getDeclaredMethod("initialize", Context.class);
                            initMethod.setAccessible(true);
                            initMethod.invoke(null, sApplication);
                            Log.i(TAG, "[GMA_INIT] MobileAds.initialize(Context) успешно вызван");
                        } catch (Throwable t) {
                            Log.d(TAG, "MobileAds.initialize note: " + t.getMessage());
                        }
                    }

                    // Поиск и установка fake InitializationStatus в статическое поле MobileAds
                    Class<?> initStatusCls = null;
                    try {
                        initStatusCls = cl.loadClass("com.google.android.gms.ads.initialization.InitializationStatus");
                    } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }

                    if (initStatusCls != null) {
                        Object fakeStatus = createFakeInitStatusProxy(initStatusCls);
                        if (fakeStatus != null) {
                            for (Field f : mobileAdsCls.getDeclaredFields()) {
                                if (Modifier.isStatic(f.getModifiers()) && initStatusCls.isAssignableFrom(f.getType())) {
                                    try {
                                        f.setAccessible(true);
                                        f.set(null, fakeStatus);
                                        Log.i(TAG, "[GMA_INIT] Fake InitializationStatus установлен в MobileAds." + f.getName());
                                    } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
                                }
                            }
                        }
                    }
                }
            } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }

            try {
                Class<?> googleUnityRewarded = cl.loadClass("com.google.unity.ads.RewardedAd");
                if (googleUnityRewarded != null) {
                    hooked = true;
                    recordProfileObservation("sdk_class", "observed", "classloader", "Google Mobile Ads", "REWARDED", "", "", "", "", googleUnityRewarded.getName());
                }
            } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
            try {
                Class<?> admobRewarded = cl.loadClass("com.google.android.gms.ads.rewarded.RewardedAd");
                if (admobRewarded != null) {
                    hooked = true;
                    recordProfileObservation("sdk_class", "observed", "classloader", "Google Mobile Ads", "REWARDED", "", "", "", "", admobRewarded.getName());
                }
            } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
        } catch (Throwable t) {
            Log.d(TAG, "GoogleMobileAds plugin hook note: " + t.getMessage());
        }
        return hooked;
    }

    private static boolean hookIronSourcePlugin() {
        boolean hooked = false;
        try {
            ClassLoader cl = getAppClassLoader();
            try {
                Class<?> ironBridge = cl.loadClass("com.ironsource.unity.androidbridge.AndroidBridge");
                if (ironBridge != null) {
                    hooked = true;
                    recordProfileObservation("sdk_class", "observed", "classloader", "IronSource/LevelPlay", "", "", "", "", "", ironBridge.getName());
                }
            } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
            try {
                Class<?> isClass = cl.loadClass("com.ironsource.mediationsdk.IronSource");
                if (isClass != null) {
                    hooked = true;
                    recordProfileObservation("sdk_class", "observed", "classloader", "IronSource/LevelPlay", "", "", "", "", "", isClass.getName());
                }
            } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
        } catch (Throwable t) {
            Log.d(TAG, "IronSource plugin hook note: " + t.getMessage());
        }
        return hooked;
    }

    private static boolean hookUnityAdsPlugin() {
        boolean hooked = false;
        try {
            ClassLoader cl = getAppClassLoader();
            try {
                Class<?> uAds = cl.loadClass("com.unity3d.ads.UnityAds");
                if (uAds != null) {
                    hooked = true;
                    recordProfileObservation("sdk_class", "observed", "classloader", "Unity Ads", "", "", "", "", "", uAds.getName());
                }
            } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
            try {
                Class<?> uImpl = cl.loadClass("com.unity3d.services.ads.unityads.UnityAdsImplementation");
                if (uImpl != null) {
                    hooked = true;
                    recordProfileObservation("sdk_class", "observed", "classloader", "Unity Ads", "", "", "", "", "", uImpl.getName());
                }
            } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
            try {
                Class<?> gmaInitCls = cl.loadClass("com.unity3d.services.ads.gmascar.finder.GMAInitializer");
                if (gmaInitCls != null) {
                    hooked = true;
                    recordProfileObservation("sdk_class", "observed", "classloader", "Unity Ads (GMA SCAR)", "BRIDGE", "", "", "", "", gmaInitCls.getName());
                }
            } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
        } catch (Throwable t) {
            Log.d(TAG, "UnityAds plugin hook note: " + t.getMessage());
        }
        return hooked;
    }

    private static boolean hookYandexAdsPlugin() {
        boolean hooked = false;
        try {
            ClassLoader cl = getAppClassLoader();
            try {
                Class<?> yndx = cl.loadClass("com.yandex.mobile.ads.rewarded.RewardedAd");
                if (yndx != null) {
                    hooked = true;
                    recordProfileObservation("sdk_class", "observed", "classloader", "Yandex Mobile Ads", "REWARDED", "", "", "", "", yndx.getName());
                }
            } catch (ClassNotFoundException ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
        } catch (Throwable t) {
            Log.d(TAG, "Yandex plugin hook note: " + t.getMessage());
        }
        return hooked;
    }

    /**
     * Рассылка эвентов "SDK Инициализирован" и "Реклама загружена"
     */
    private static void broadcastFakeInitAndLoadedState() {
        if (sKnownAdUnitIds.isEmpty()) {
            return; // Никакой рассылки, пока реальные AdUnitId не были получены в runtime
        }
        Set<String> unitsToSend = new HashSet<>(sKnownAdUnitIds);

        // 1. AppLovin MAX BackgroundCallback
        if (sMaxBackgroundCallback == null) {
            hookAppLovinMaxPlugin();
        }
        if (sMaxBackgroundCallback != null) {
            try {
                for (Method cbMethod : sMaxBackgroundCallback.getClass().getDeclaredMethods()) {
                    if (cbMethod.getParameterTypes().length == 1 && cbMethod.getParameterTypes()[0] == String.class) {
                        cbMethod.setAccessible(true);
                        String initJson = "{\"name\":\"OnSdkInitializedEvent\",\"hasUserConsent\":true,\"isAgeRestrictedUser\":false,\"isDoNotSell\":false,\"countryCode\":\"US\"}";
                        cbMethod.invoke(sMaxBackgroundCallback, initJson);

                        for (String adUnitId : unitsToSend) {
                            DynamicAdMeta meta = sDynamicAdMetaMap.get(adUnitId);
                            String creativeId = (meta != null) ? meta.getCreativeIdentifier() : ("cr_" + Long.toHexString((System.currentTimeMillis() ^ (long) adUnitId.hashCode()) & 0xFFFFFFFFL));
                            String netPlacement = (meta != null && !meta.networkPlacement.isEmpty()) ? meta.networkPlacement : "";
                            String placement = meta != null ? meta.placement : "";
                            String netName = (meta != null && !meta.networkName.isEmpty()) ? meta.networkName : "AppLovin";
                            double rev = meta != null ? meta.revenue : 0.05;

                            String loadedJson = "{\"name\":\"OnRewardedAdLoadedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";
                            String loadedInterJson = "{\"name\":\"OnInterstitialLoadedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"INTER\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";
                            cbMethod.invoke(sMaxBackgroundCallback, loadedJson);
                            cbMethod.invoke(sMaxBackgroundCallback, loadedInterJson);
                        }
                        break;
                    }
                }
            } catch (Throwable t) {
                Log.d(TAG, "sMaxBackgroundCallback broadcast note: " + t.getMessage());
            }
        }

        // 2. UnityPlayer UnitySendMessage
        try {
            ClassLoader cl = getAppClassLoader();
            Class<?> unityPlayer = cl.loadClass("com.unity3d.player.UnityPlayer");
            Method sendMsg = unityPlayer.getDeclaredMethod("UnitySendMessage", String.class, String.class, String.class);
            sendMsg.setAccessible(true);

            // AppLovin MAX & MobileAdsHandler
            for (String adUnitId : unitsToSend) {
                DynamicAdMeta meta = sDynamicAdMetaMap.get(adUnitId);
                String creativeId = (meta != null) ? meta.getCreativeIdentifier() : ("cr_" + Long.toHexString((System.currentTimeMillis() ^ (long) adUnitId.hashCode()) & 0xFFFFFFFFL));
                String netPlacement = (meta != null && !meta.networkPlacement.isEmpty()) ? meta.networkPlacement : "";
                String placement = meta != null ? meta.placement : "";
                String netName = (meta != null && !meta.networkName.isEmpty()) ? meta.networkName : "AppLovin";
                double rev = meta != null ? meta.revenue : 0.05;

                String loadedJson = "{\"name\":\"OnRewardedAdLoadedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";
                String loadedInterJson = "{\"name\":\"OnInterstitialLoadedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"INTER\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";
                sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", loadedJson);
                sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", loadedInterJson);
            }

            // Google Mobile Ads (AdMob)
            sendMsg.invoke(null, "GoogleMobileAdsCallbacks", "onRewardedAdLoaded", "");
            sendMsg.invoke(null, "GoogleMobileAdsCallbacks", "onAdLoaded", "");
            sendMsg.invoke(null, "GoogleMobileAdsRewardedAdClient", "onRewardedAdLoaded", "");
            sendMsg.invoke(null, "GoogleMobileAdsRewardedAdClient", "onAdLoaded", "");

            // IronSource LevelPlay
            sendMsg.invoke(null, "IronSourceEvents", "onRewardedVideoAvailabilityChanged", "{\"available\":\"true\"}");
            sendMsg.invoke(null, "IronSourceEvents", "onRewardedVideoAvailabilityChanged", "true");

            // Unity Ads
            sendMsg.invoke(null, "UnityAdsCallbacks", "onUnityAdsAdLoaded", "rewardedVideo");
            sendMsg.invoke(null, "UnityAdsCallbacks", "onUnityAdsReady", "rewardedVideo");

            // Yandex Mobile Ads
            sendMsg.invoke(null, "YandexMobileAdsCallback", "OnAdLoaded", "");
        } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
    }

    public static void scanAndTriggerAdObjects() {
        // Безопасное сканирование ActivityThread без вмешательства во внутренние View системы
        try {
            Class<?> activityThreadClass = Class.forName("android.app.ActivityThread");
            Method currentActivityThreadMethod = activityThreadClass.getDeclaredMethod("currentActivityThread");
            currentActivityThreadMethod.setAccessible(true);
            Object activityThread = currentActivityThreadMethod.invoke(null);
            if (activityThread != null) {
                Field activitiesField = activityThreadClass.getDeclaredField("mActivities");
                activitiesField.setAccessible(true);
                Object activitiesObj = activitiesField.get(activityThread);
                if (activitiesObj instanceof Map) {
                    Map<?, ?> actMap = (Map<?, ?>) activitiesObj;
                    for (Object record : actMap.values()) {
                        if (record == null) continue;
                        try {
                            Field actField = record.getClass().getDeclaredField("activity");
                            actField.setAccessible(true);
                            Activity act = (Activity) actField.get(record);
                            if (act != null && !isStrictAdActivity(act)) {
                                attachBannerCollapser(act);
                            }
                        } catch (Throwable t) {
                            Log.d(TAG, "ActivityRecord scan note: " + t.getMessage());
                        }
                    }
                }
            }
        } catch (Throwable t) {
            Log.d(TAG, "ActivityThread scan note: " + t.getMessage());
        }
    }

    private static String inferSdkFromClassName(String className) {
        if (className == null) return "";
        String n = className.toLowerCase();
        if (n.contains("applovin") || n.contains("maxsdk") || n.contains("maxrewarded")) return "AppLovin MAX";
        if (n.contains("google.android.gms.ads") || n.contains("admob")) return "Google Mobile Ads";
        if (n.contains("unityads") || n.contains("unity3d.services.ads")) return "Unity Ads";
        if (n.contains("ironsource") || n.contains("levelplay")) return "IronSource/LevelPlay";
        if (n.contains("yandex.mobile.ads")) return "Yandex Mobile Ads";
        if (n.contains("vungle")) return "Vungle/Liftoff";
        if (n.contains("mbridge") || n.contains("mintegral")) return "Mintegral";
        if (n.contains("bytedance") || n.contains("openadsdk") || n.contains("pangle")) return "Pangle";
        if (n.contains("inmobi")) return "InMobi";
        if (n.contains("chartboost")) return "Chartboost";
        if (n.contains("my.target") || n.contains("mytarget")) return "MyTarget";
        return "";
    }

    private static String inferFormatFromText(String text) {
        if (text == null) return "";
        String n = text.toLowerCase();
        if (n.contains("reward")) return "REWARDED";
        if (n.contains("interstitial")) return "INTERSTITIAL";
        if (n.contains("appopen") || n.contains("app_open")) return "APP_OPEN";
        if (n.contains("native")) return "NATIVE";
        if (n.contains("banner")) return "BANNER";
        return "";
    }

    private static void observeAdField(Object owner, Field field, Object value) {
        if (owner == null || field == null || !(value instanceof String)) return;
        String v = ((String) value).trim();
        if (v.isEmpty() || v.length() > 512) return;
        String fn = field.getName().toLowerCase();
        String cls = owner.getClass().getName();
        String sdk = inferSdkFromClassName(cls);
        String fmt = inferFormatFromText(cls + " " + field.getName());
        String src = "reflection:" + cls + "." + field.getName();

        if (fn.equals("adunitid") || fn.equals("ad_unit_id") || fn.equals("adunitidentifier")
                || fn.equals("unitid") || fn.equals("placementid") || fn.equals("placement_id")) {
            rememberAdUnit(v, "observed", src, sdk, fmt);
        } else if (fn.equals("placement") || fn.equals("networkplacement")) {
            recordProfileObservation("placement", "observed", src, sdk, fmt, "", v, "", "", "");
        } else if (fn.equals("rewardtype") || fn.equals("rewardlabel") || fn.equals("rewardname")) {
            recordProfileObservation("reward_metadata", "observed", src, sdk, fmt, "", "", v, "", "");
        }
    }

    private static void scanObjectForAdListeners(Object obj, int depth) {
        if (obj == null || depth > 2) return;
        Class<?> cls = obj.getClass();
        String clsName = cls.getName();

        if (clsName.startsWith("android.view.") || clsName.startsWith("java.") || clsName.startsWith("javax.")) {
            if (!(obj instanceof ViewGroup)) return;
        }

        if (sScannedObjects.contains(obj)) return;

        checkAndActivateAdObject(obj);

        boolean hasAdFields = false;
        while (cls != null && cls != Object.class && !cls.getName().startsWith("android.content.")) {
            Field[] fields = cls.getDeclaredFields();
            for (Field f : fields) {
                if (Modifier.isStatic(f.getModifiers())) continue;
                try {
                    f.setAccessible(true);
                    Object val = f.get(obj);
                    if (val == null) continue;
                    observeAdField(obj, f, val);
                    if (checkAndActivateAdObject(val)) {
                        hasAdFields = true;
                    }
                } catch (Throwable t) {
                    Log.d(TAG, "Field scan note: " + t.getMessage());
                }
            }
            cls = cls.getSuperclass();
        }

        if (!hasAdFields && depth == 0 && !(obj instanceof ViewGroup)) {
            sScannedObjects.add(obj);
        }

        if (obj instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) obj;
            int childCount = Math.min(vg.getChildCount(), 20);
            for (int i = 0; i < childCount; i++) {
                scanObjectForAdListeners(vg.getChildAt(i), depth + 1);
            }
        }
    }

    private static boolean checkAndActivateAdObject(Object obj) {
        if (obj == null) return false;
        String name = obj.getClass().getName();

        // Строгая защита системных, сетевых и UI библиотек
        if (name.startsWith("android.") || name.startsWith("androidx.") || name.startsWith("java.") ||
            name.startsWith("javax.") || name.startsWith("org.chromium.") || name.startsWith("com.microsoft.") ||
            name.startsWith("org.telegram.") || name.startsWith("okhttp3.") || name.startsWith("retrofit2.") ||
            name.startsWith("io.netty.") || name.startsWith("com.google.protobuf.") || name.startsWith("kotlin.")) {
            // Исключение строго для com.google.android.gms.ads
            if (!name.startsWith("com.google.android.gms.ads.")) {
                return false;
            }
        }

        String inferredSdk = inferSdkFromClassName(name);
        if (inferredSdk.isEmpty()) {
            // Если класс не принадлежит ни одному рекламному SDK, не трогаем его!
            return false;
        }

        recordProfileObservation("sdk_runtime_object", "inferred", "class_name", inferredSdk,
                inferFormatFromText(name), "", "", "", "", name);

        // 1. Инициализация SDK
        if (name.contains("InitializationCompleteListener") || name.contains("SdkInitializationListener") ||
            name.contains("IUnityAdsInitializationListener") || name.contains("InitializationListener")) {
            activateInitListener(obj);
            return true;
        }

        // 2. Слушатели рекламы и наград
        if (name.contains("RewardedAdLoader") || name.contains("RewardedAdLoadCallback") ||
            name.contains("RewardedAd") || name.contains("AdLoadListener") ||
            name.contains("RewardedAdEventListener") || name.contains("OnUserEarnedRewardListener") ||
            name.contains("MaxRewardedAd") || name.contains("MaxAdListener") ||
            name.contains("IUnityAdsListener") || name.contains("IUnityAdsShowListener") ||
            name.contains("IUnityAdsLoadListener") || name.contains("UnityRewardedAdCallback")) {
            activateAdListener(obj);
            return true;
        }
        return false;
    }

    private static void activateInitListener(final Object initObj) {
        if (initObj == null || sHandledInitListeners.contains(initObj)) return;

        sMainHandler.post(new Runnable() {
            @Override
            public void run() {
                try {
                    Class<?> cls = initObj.getClass();
                    boolean handled = false;

                    for (Method m : cls.getMethods()) {
                        String mName = m.getName();
                        if ("onInitializationComplete".equals(mName) || "onInitializationCompleted".equals(mName) ||
                            "onSdkInitialized".equals(mName) || "onAdapterInitializationComplete".equals(mName)) {
                            Class<?>[] pts = m.getParameterTypes();
                            if (pts.length == 1) {
                                Object fakeStatus = createFakeInitStatusProxy(pts[0]);
                                m.invoke(initObj, fakeStatus);
                                handled = true;
                                Log.i(TAG, "[FAKE_INIT] >>> onInitializationComplete(" + pts[0].getSimpleName() + ") вызван для " + cls.getName() + " <<<");
                            } else if (pts.length == 0) {
                                m.invoke(initObj);
                                handled = true;
                                Log.i(TAG, "[FAKE_INIT] >>> onInitializationComplete() без параметров вызван для " + cls.getName() + " <<<");
                            }
                        }
                    }

                    if (handled) sHandledInitListeners.add(initObj);
                } catch (Throwable t) {
                    Log.w(TAG, "Ошибка activateInitListener (" + initObj.getClass().getName() + "): " + t.getMessage(), t);
                }
            }
        });
    }

    private static Object createFakeAdapterStatusProxy(ClassLoader cl) {
        if (cl == null) return null;
        try {
            Class<?> adapterStatusCls = Class.forName("com.google.android.gms.ads.initialization.AdapterStatus", false, cl);
            if (adapterStatusCls == null) return null;

            Object readyEnumObj = null;
            try {
                Class<?> stateEnumCls = Class.forName("com.google.android.gms.ads.initialization.AdapterStatus$State", false, cl);
                if (stateEnumCls != null && stateEnumCls.isEnum()) {
                    for (Object constant : stateEnumCls.getEnumConstants()) {
                        if ("READY".equalsIgnoreCase(String.valueOf(constant))) {
                            readyEnumObj = constant;
                            break;
                        }
                    }
                }
            } catch (Throwable t) {
                // Игнорируем отсутствие enum в старых версиях SDK
            }
            final Object readyEnum = readyEnumObj;

            Class<?>[] interfaces = adapterStatusCls.isInterface() ? new Class<?>[]{adapterStatusCls} : adapterStatusCls.getInterfaces();
            if (interfaces.length == 0) return null;

            return Proxy.newProxyInstance(
                cl,
                interfaces,
                new InvocationHandler() {
                    @Override
                    public Object invoke(Object proxy, Method method, Object[] args) {
                        String mName = method.getName();
                        if ("hashCode".equals(mName) && method.getParameterTypes().length == 0) return System.identityHashCode(proxy);
                        if ("equals".equals(mName) && args != null && args.length == 1) return proxy == args[0];
                        if ("getInitializationState".equals(mName)) return readyEnum;
                        if ("getDescription".equals(mName)) return "READY";
                        if ("getLatency".equals(mName)) return Integer.valueOf(0);
                        if ("toString".equals(mName)) return "SmartRewardFakeAdapterStatus[READY, latency=0]";

                        Class<?> retType = method.getReturnType();
                        if (retType == boolean.class || retType == Boolean.class) return Boolean.TRUE;
                        if (retType == int.class || retType == Integer.class) return Integer.valueOf(0);
                        if (retType == String.class) return "READY";
                        return null;
                    }
                }
            );
        } catch (Throwable t) {
            Log.d(TAG, "FakeAdapterStatus note: " + t.getMessage());
            return null;
        }
    }

    private static Object createFakeInitStatusProxy(final Class<?> statusClass) {
        if (statusClass == null) return null;
        try {
            final ClassLoader cl = getAppClassLoader();
            Class<?>[] interfaces = statusClass.isInterface() ? new Class<?>[]{statusClass} : statusClass.getInterfaces();
            if (interfaces.length == 0) return null;

            return Proxy.newProxyInstance(
                cl,
                interfaces,
                new InvocationHandler() {
                    @Override
                    public Object invoke(Object proxy, Method method, Object[] args) {
                        String mName = method.getName();
                        if ("hashCode".equals(mName) && method.getParameterTypes().length == 0) return System.identityHashCode(proxy);
                        if ("equals".equals(mName) && args != null && args.length == 1) return proxy == args[0];
                        if ("getAdapterStatusMap".equals(mName)) {
                            final Object fakeAdapter = createFakeAdapterStatusProxy(cl);
                            if (fakeAdapter != null) {
                                HashMap<String, Object> map = new HashMap<String, Object>() {
                                    public Object get(Object key) {
                                        return fakeAdapter;
                                    }
                                    public boolean containsKey(Object key) {
                                        return true;
                                    }
                                    public boolean isEmpty() {
                                        return false;
                                    }
                                    public int size() {
                                        return 1;
                                    }
                                };
                                map.put("com.google.android.gms.ads.MobileAds", fakeAdapter);
                                map.put("com.google.ads.mediation.admob.AdMobAdapter", fakeAdapter);
                                map.put("com.unity3d.services.ads.gmascar.finder.GMAInitializer", fakeAdapter);
                                map.put("default", fakeAdapter);
                                return map;
                            }
                            return Collections.emptyMap();
                        }
                        if ("toString".equals(mName)) return "SmartRewardFakeInitStatus[READY]";
                        
                        Class<?> retType = method.getReturnType();
                        String mnLower = mName.toLowerCase();
                        if (retType == boolean.class || retType == Boolean.class) {
                            if (mnLower.contains("init") || mnLower.contains("ready") || mnLower.contains("success")) return true;
                            if (mnLower.contains("error") || mnLower.contains("fail") || mnLower.contains("retry") || mnLower.contains("cancel")) return false;
                            return false;
                        }
                        if (retType == int.class || retType == Integer.class) {
                            if (mnLower.contains("code") || mnLower.contains("error")) return 0;
                            if (mnLower.contains("state") || mnLower.contains("status")) return 1; // 1 = READY
                            return 0;
                        }
                        if (retType == String.class) {
                            if (mnLower.contains("state") || mnLower.contains("status") || mnLower.contains("message")) return "READY";
                            if (mnLower.contains("error") || mnLower.contains("description")) return "";
                            return "READY";
                        }
                        if (retType == Map.class) return Collections.emptyMap();
                        if (retType == List.class) return Collections.emptyList();
                        return null;
                    }
                }
            );
        } catch (Throwable t) {
            Log.d(TAG, "FakeInitStatus note: " + t.getMessage());
            return null;
        }
    }

    private static void activateAdListener(final Object adObj) {
        if (adObj == null || sHandledLoadListeners.contains(adObj)) return;

        sMainHandler.post(new Runnable() {
            @Override
            public void run() {
                try {
                    Class<?> cls = adObj.getClass();
                    boolean handled = false;

                    // 1. Google AdMob, Yandex, UnityAds Loaders -> принудительный успешный коллбек
                    for (Method m : cls.getMethods()) {
                        String mName = m.getName();
                        if ("onAdLoaded".equals(mName) || "onRewardedAdLoaded".equals(mName) || "onUnityAdsAdLoaded".equals(mName)) {
                            Class<?>[] pts = m.getParameterTypes();
                            if (pts.length == 1) {
                                if (pts[0] == String.class) {
                                    m.invoke(adObj, "rewardedVideo");
                                    handled = true;
                                    Log.i(TAG, "[FAKE_AD_LOADED] >>> onUnityAdsAdLoaded(\"rewardedVideo\") вызван для " + cls.getName() + " <<<");
                                } else {
                                    Object fakeAd = createFakeRewardedAdProxy(pts[0]);
                                    if (fakeAd != null) {
                                        m.invoke(adObj, fakeAd);
                                        handled = true;
                                        Log.i(TAG, "[FAKE_AD_LOADED] >>> Имитация загрузки рекламы передана в " + cls.getName() + " <<<");
                                    }
                                }
                            } else if (pts.length == 0) {
                                m.invoke(adObj);
                                handled = true;
                                Log.i(TAG, "[FAKE_AD_LOADED] >>> onAdLoaded() вызван для " + cls.getName() + " <<<");
                            }
                        }
                    }

                    // 2. Слушатели наград
                    if (cls.getName().contains("RewardedAdEventListener") ||
                        cls.getName().contains("OnUserEarnedRewardListener") ||
                        cls.getName().contains("MaxAdListener") ||
                        cls.getName().contains("MaxRewardedAdListener") ||
                        cls.getName().contains("IUnityAdsListener") ||
                        cls.getName().contains("UnityRewardedAdCallback")) {
                        sRegisteredRewardListeners.add(adObj);
                        handled = true;
                    }
                    if (handled) sHandledLoadListeners.add(adObj);
                } catch (Throwable t) {
                    Log.w(TAG, "Ошибка activateAdListener (" + adObj.getClass().getName() + "): " + t.getMessage(), t);
                }
            }
        });
    }

    private static Object createFakeRewardedAdProxy(final Class<?> adClass) {
        if (adClass == null) return null;
        try {
            ClassLoader cl = getAppClassLoader();
            Class<?>[] interfaces = adClass.isInterface() ? new Class<?>[]{adClass} : adClass.getInterfaces();
            if (interfaces.length == 0) {
                try {
                    Class<?> yandexIf = cl.loadClass("com.yandex.mobile.ads.rewarded.RewardedAd");
                    interfaces = new Class<?>[]{yandexIf};
                } catch (Throwable t) {
                    Log.d(TAG, "RewardedAd interface note: " + t.getMessage());
                    return null;
                }
            }

            return Proxy.newProxyInstance(
                cl,
                interfaces,
                new InvocationHandler() {
                    private Object mEventListener = null;

                    @Override
                    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
                        String mName = method.getName();
                        if ("hashCode".equals(mName) && method.getParameterTypes().length == 0) return System.identityHashCode(proxy);
                        if ("equals".equals(mName) && args != null && args.length == 1) return proxy == args[0];
                        if ("toString".equals(mName) && method.getParameterTypes().length == 0) return "SmartRewardFakeAd";

                        // Все проверки готовности принудительно возвращают true
                        if ("isLoaded".equals(mName) || "isReady".equals(mName) || "isAvailable".equals(mName) ||
                            "canShowAd".equals(mName) || "canPlayAd".equals(mName) || "has_video_ad".equals(mName)) {
                            Log.i(TAG, "[FAKE_AD_LOADED] Запрос " + mName + "() -> true");
                            return true;
                        }

                        if ("setAdEventListener".equals(mName) || "setRewardedAdEventListener".equals(mName) ||
                            "setListener".equals(mName) || "setFullScreenContentCallback".equals(mName) ||
                            "setInteractionListener".equals(mName) || "setRewardListener".equals(mName)) {
                            if (args != null && args.length > 0 && args[0] != null) {
                                mEventListener = args[0];
                                sRegisteredRewardListeners.add(mEventListener);
                            }
                            return null;
                        }

                        if ("show".equals(mName) || "showAd".equals(mName) || "showRewardedAd".equals(mName) ||
                            "play".equals(mName) || "playAd".equals(mName)) {
                            if (args != null) {
                                for (Object arg : args) {
                                    if (arg != null && !(arg instanceof Activity) && !arg.getClass().getName().startsWith("android.")) {
                                        sRegisteredRewardListeners.add(arg);
                                        // Прямой вызов OnUserEarnedRewardListener (Google Mobile Ads / Android SDKs)
                                        for (Method cbM : arg.getClass().getMethods()) {
                                            if ("onUserEarnedReward".equals(cbM.getName())) {
                                                try {
                                                    Class<?>[] pts = cbM.getParameterTypes();
                                                    if (pts.length == 1) {
                                                        Object rObj = createFakeRewardProxy(pts[0]);
                                                        cbM.invoke(arg, rObj);
                                                    } else {
                                                        cbM.invoke(arg);
                                                    }
                                                    Log.i(TAG, "[GMA_REWARD] Direct OnUserEarnedRewardListener invoked for " + arg.getClass().getName());
                                                } catch (Throwable t) {
                                                    Log.d(TAG, "Direct GMA reward note: " + t.getMessage());
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            Log.i(TAG, "[FAKE_AD_SHOW] >>> Нажата кнопка просмотра! (" + mName + ") Выдача награды <<<");
                            triggerAllRewardListeners("FakeRewardedAd." + mName);
                            return null;
                        }

                        if ("getAdMetadata".equals(mName)) {
                            return new Bundle();
                        }
                        if ("getAdUnitId".equals(mName) || "getPlacementId".equals(mName)) {
                            return !sKnownAdUnitIds.isEmpty() ? sKnownAdUnitIds.iterator().next() : "";
                        }
                        if ("getRewardItem".equals(mName) || "getReward".equals(mName)) {
                            return createFakeRewardProxy(method.getReturnType());
                        }
                        if ("getResponseInfo".equals(mName)) {
                            return createFakeResponseInfoProxy(method.getReturnType());
                        }

                        Class<?> retType = method.getReturnType();
                        if (retType == boolean.class || retType == Boolean.class) {
                            String mnLower = mName.toLowerCase();
                            // Позитивные флаги готовности
                            if (mnLower.contains("loaded") || mnLower.contains("ready") || mnLower.contains("available") ||
                                mnLower.contains("canshow") || mnLower.contains("hasvideo")) {
                                return true;
                            }
                            // Негативные флаги (ошибки, истечение срока, уничтожение)
                            if (mnLower.contains("error") || mnLower.contains("expired") || mnLower.contains("destroyed") ||
                                mnLower.contains("muted") || mnLower.contains("test") || mnLower.contains("loading") ||
                                mnLower.contains("fail")) {
                                return false;
                            }
                            return false;
                        }
                        if (retType == int.class || retType == Integer.class) {
                            String mnLower = mName.toLowerCase();
                            if (mnLower.contains("error") || mnLower.contains("code")) return 0;
                            if (mnLower.contains("amount") || mnLower.contains("reward")) return 1;
                            return 0;
                        }
                        if (retType == String.class) {
                            String mnLower = mName.toLowerCase();
                            if (mnLower.contains("type") || mnLower.contains("label")) {
                                for (DynamicAdMeta meta : sDynamicAdMetaMap.values()) {
                                    if (meta != null && !meta.rewardLabel.isEmpty()) return meta.rewardLabel;
                                }
                                return "";
                            }
                            if (mnLower.contains("unit") || mnLower.contains("placement")) {
                                return !sKnownAdUnitIds.isEmpty() ? sKnownAdUnitIds.iterator().next() : "";
                            }
                            return "";
                        }
                        if (retType == Bundle.class) return new Bundle();
                        return null;
                    }
                }
            );
        } catch (Throwable t) {
            Log.w(TAG, "Не удалось создать Fake RewardedAd Proxy: " + t.getMessage(), t);
            return null;
        }
    }

    private static boolean isStrictAdActivity(Activity activity) {
        if (activity == null) return false;
        try {
            if (activity.isTaskRoot()) return false;
        } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }

        String name = activity.getClass().getName();
        
        // Никогда не закрывать экраны движков и игровые активности
        if (name.contains("Unity") || name.contains("Game") || name.contains("Player") ||
            name.contains("MainActivity") || name.contains("Singular") || name.contains("AppActivity")) {
            return false;
        }

        // Никогда не закрывать собственные экраны приложения (если это не внутренний ad renderer)
        if (name.startsWith(activity.getPackageName()) &&
            !name.contains(".ads.") && !name.contains(".ad.") && !name.contains("Mraid") && !name.contains("AdActivity")) {
            return false;
        }

        if (STRICT_AD_ACTIVITIES.contains(name)) return true;

        // Авто-детекция любых экранов рекламы по пакетам известных SDK
        if (name.startsWith("com.unity3d.ads.") || name.startsWith("com.unity3d.services.ads.") ||
            name.startsWith("com.applovin.") || name.startsWith("com.google.android.gms.ads.") ||
            name.startsWith("com.facebook.ads.") || name.startsWith("com.ironsource.") ||
            name.startsWith("com.vungle.") || name.startsWith("com.mbridge.msdk.") ||
            name.startsWith("com.mintegral.msdk.") || name.startsWith("com.bytedance.sdk.openadsdk.") ||
            name.startsWith("com.pangle.") || name.startsWith("com.moloco.") ||
            name.startsWith("com.yandex.mobile.ads.") || name.startsWith("com.adcolony.") ||
            name.startsWith("com.chartboost.") || name.startsWith("com.inmobi.") ||
            name.startsWith("com.fyber.") || name.startsWith("com.hyprmx.") ||
            name.startsWith("com.bidmachine.") || name.startsWith("com.ogury.") ||
            name.startsWith("com.tapjoy.") || name.startsWith("com.amazon.device.ads.") ||
            name.startsWith("com.criteo.") || name.startsWith("com.verve.") ||
            name.contains("FullScreenWebViewDisplay") || name.contains("AudienceNetworkActivity") ||
            name.contains("AdActivity") || name.contains("FullscreenActivity") ||
            name.contains("MraidActivity") || name.contains("mraid") ||
            name.contains("InterstitialActivity") || name.contains("RewardedActivity") ||
            name.contains("AdViewActivity") || name.contains("VideoActivity") ||
            name.contains("AdPlayer") || name.contains("AdRenderer") || name.contains("VastActivity")) {
            return true;
        }

        return false;
    }

    private static void registerLifecycleCallbacks(Application app) {
        if (app == null || !sLifecycleRegistered.compareAndSet(false, true)) return;
        app.registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
            @Override
            public void onActivityCreated(Activity activity, Bundle savedInstanceState) {
                setRuntimePhase(RuntimePhase.ACTIVITY_READY,
                        activity != null ? activity.getClass().getName() : "activity-created");
                if (activity != null && isStrictAdActivity(activity)) {
                    fastPassAdActivity(activity);
                }
            }

            @Override
            public void onActivityStarted(Activity activity) {
                if (activity != null && isStrictAdActivity(activity)) {
                    fastPassAdActivity(activity);
                }
            }

            @Override
            public void onActivityResumed(Activity activity) {
                setRuntimePhase(RuntimePhase.PASSIVE_RUNTIME,
                        activity != null ? activity.getClass().getName() : "activity-resumed");
                if (activity != null && isStrictAdActivity(activity)) {
                    fastPassAdActivity(activity);
                } else if (activity != null) {
                    attachBannerCollapser(activity);
                    schedulePluginHooks();
                }
            }

            @Override
            public void onActivityPaused(Activity activity) {}
            @Override
            public void onActivityStopped(Activity activity) {}
            @Override
            public void onActivitySaveInstanceState(Activity activity, Bundle outState) {}
            @Override
            public void onActivityDestroyed(Activity activity) {}
        });

        try {
            IntentFilter filter = new IntentFilter("ecubz.smartreward.TRIGGER_REWARD");
            BroadcastReceiver receiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    Log.i(TAG, "[ADB_TRIGGER] >>> Получена команда мгновенного начисления наград! <<<");
                    String adUnit = intent.getStringExtra("ad_unit");
                    if (adUnit == null || adUnit.isEmpty()) {
                        adUnit = !sKnownAdUnitIds.isEmpty() ? sKnownAdUnitIds.iterator().next() : "";
                    }
                    if (!adUnit.isEmpty()) {
                        rememberAdUnit(adUnit, "synthetic", "adb_trigger", "", "REWARDED");
                    }
                    triggerAllRewardListeners("AdbBroadcastTrigger");
                }
            };
            if (Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED);
            } else {
                app.registerReceiver(receiver, filter);
            }
            Log.i(TAG, "[ADB_TRIGGER] Зарегистрирован BroadcastReceiver (ecubz.smartreward.TRIGGER_REWARD)");
        } catch (Throwable t) {
            Log.d(TAG, "BroadcastReceiver register note: " + t.getMessage());
        }
    }

    private static void fastPassAdActivity(final Activity activity) {
        if (activity == null || !isStrictAdActivity(activity)) return;
        try {
            Log.i(TAG, "Fast-Pass: безопасная выгрузка AdActivity: " + activity.getClass().getName());
            triggerAllRewardListeners("FastPass-" + activity.getClass().getSimpleName());

            sMainHandler.post(new Runnable() {
                @Override
                public void run() {
                    try {
                        if (activity != null && !activity.isFinishing() && !activity.isDestroyed()) {
                            try {
                                if (activity.isTaskRoot()) return;
                            } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
                            activity.finish();
                            activity.overridePendingTransition(0, 0);
                        }
                    } catch (Throwable ignored) { /* глушение-обосновано: опциональный класс SDK или безопасная обработка */ }
                }
            });
        } catch (Throwable t) {
            Log.w(TAG, "Ошибка в fastPassAdActivity: " + t.getMessage(), t);
        }
    }

    public static void triggerAllRewardListeners(final String reason) {
        sMainHandler.post(new Runnable() {
            @Override
            public void run() {
                try {
                    Log.i(TAG, ">>> ТРИГГЕР НАЧИСЛЕНИЯ НАГРАДЫ (Причина: " + reason + ") <<<");

                    // 1. Оповещение слушателей Java с внешней синхронизацией
                    synchronized (sRegisteredRewardListeners) {
                        for (Object listener : sRegisteredRewardListeners) {
                            if (listener == null) continue;
                            try {
                                for (Method m : listener.getClass().getMethods()) {
                                    String mName = m.getName();

                                    if ("onRewarded".equals(mName) || "onUserEarnedReward".equals(mName) ||
                                        "onUserRewarded".equals(mName) || "onRewardedVideoCompleted".equals(mName)) {
                                        Class<?>[] pts = m.getParameterTypes();
                                        if (pts.length == 1) {
                                            Object proxyReward = createFakeRewardProxy(pts[0]);
                                            m.invoke(listener, proxyReward);
                                            Log.i(TAG, "[TRIGGER] Вызван метод с 1 параметром: " + listener.getClass().getName() + "." + mName);
                                        } else if (pts.length == 2) {
                                            if (pts[0] == String.class && (pts[1] == float.class || pts[1] == double.class || pts[1] == int.class)) {
                                                m.invoke(listener, "reward", 1.0f);
                                                Log.i(TAG, "[TRIGGER] Google Unity Proxy onUserEarnedReward(\"reward\", 1.0f) вызван!");
                                            } else {
                                                Object proxyReward = createFakeRewardProxy(pts[1]);
                                                m.invoke(listener, null, proxyReward);
                                                Log.i(TAG, "[TRIGGER] Вызван метод с 2 параметрами: " + listener.getClass().getName() + "." + mName);
                                            }
                                        } else if (pts.length == 0) {
                                            m.invoke(listener);
                                            Log.i(TAG, "[TRIGGER] Вызван метод без параметров: " + mName);
                                        }
                                    }

                                    if ("onUnityAdsFinish".equals(mName) || "onUnityAdsShowComplete".equals(mName)) {
                                        Class<?>[] pts = m.getParameterTypes();
                                        if (pts.length == 2) {
                                            Object finishState = getUnityFinishStateEnum(pts[1]);
                                            m.invoke(listener, "rewardedVideo", finishState);
                                            Log.i(TAG, "[TRIGGER] UnityAds listener notified: " + mName);
                                        } else if (pts.length == 1) {
                                            m.invoke(listener, "rewardedVideo");
                                        }
                                    }

                                    if ("onAdDismissed".equals(mName) || "onAdClosed".equals(mName) ||
                                        "onAdHidden".equals(mName) || "onAdDismissedFullScreenContent".equals(mName)) {
                                        try { m.invoke(listener); } catch (Throwable t) { Log.d(TAG, "Dismiss note: " + t.getMessage()); }
                                    }
                                }
                            } catch (Throwable t) {
                                Log.w(TAG, "Ошибка при оповещении слушателя наград: " + t.getMessage());
                            }
                        }
                    }

                    // 2. Оповещение мостов движков (Unity / Godot / Cocos)
                    notifyUnityRewardCallbacks();
                    
                    // 3. Оповещение AppLovin MAX BackgroundCallback
                    if (sMaxBackgroundCallback != null) {
                        try {
                            Method cbMethod = null;
                            for (Method m : sMaxBackgroundCallback.getClass().getDeclaredMethods()) {
                                if (m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == String.class) {
                                    String mName = m.getName().toLowerCase();
                                    if (mName.contains("callback") || mName.contains("forward") || mName.contains("event") || mName.contains("on")) {
                                        cbMethod = m;
                                        break;
                                    }
                                    if (cbMethod == null) cbMethod = m;
                                }
                            }
                            if (cbMethod != null) {
                                cbMethod.setAccessible(true);
                                Set<String> units = new HashSet<>(sKnownAdUnitIds);
                                if (units.isEmpty()) units.add("default_rewarded");
                                for (String adUnitId : units) {
                                    DynamicAdMeta meta = sDynamicAdMetaMap.get(adUnitId);
                                    String creativeId = (meta != null) ? meta.getCreativeIdentifier() : ("cr_" + Long.toHexString((System.currentTimeMillis() ^ (long) adUnitId.hashCode()) & 0xFFFFFFFFL));
                                    String netPlacement = (meta != null && !meta.networkPlacement.isEmpty()) ? meta.networkPlacement : "";
                                    String placement = meta != null ? meta.placement : "";
                                    String netName = (meta != null && !meta.networkName.isEmpty()) ? meta.networkName : "AppLovin";
                                    String rLabel = (meta != null && !meta.rewardLabel.isEmpty()) ? meta.rewardLabel : "";
                                    double rAmt = (meta != null && meta.rewardAmount > 0) ? meta.rewardAmount : 1.0;
                                    double rev = (meta != null && meta.revenue > 0) ? meta.revenue : 0.05;

                                    String displayedJson = "{\"name\":\"OnRewardedAdDisplayedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\"}}";
                                    String rewardJson = "{\"name\":\"OnRewardedAdReceivedRewardEvent\",\"adUnitId\":\"" + adUnitId + "\",\"rewardLabel\":\"" + rLabel + "\",\"rewardAmount\":" + rAmt + ",\"reward\":{\"label\":\"" + rLabel + "\",\"amount\":" + rAmt + "},\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";
                                    String hiddenJson = "{\"name\":\"OnRewardedAdHiddenEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\"}}";
                                    String loadedJson = "{\"name\":\"OnRewardedAdLoadedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";

                                    cbMethod.invoke(sMaxBackgroundCallback, displayedJson);
                                    cbMethod.invoke(sMaxBackgroundCallback, rewardJson);
                                    cbMethod.invoke(sMaxBackgroundCallback, hiddenJson);
                                    cbMethod.invoke(sMaxBackgroundCallback, loadedJson);
                                }
                            }
                        } catch (Throwable t) {
                            Log.d(TAG, "sMaxBackgroundCallback trigger note: " + t.getMessage());
                        }
                    }

                    // 4. Автоматическая перезарядка статуса готовности (Auto-Rearm)
                    broadcastFakeInitAndLoadedState();
                } catch (Throwable t) {
                    Log.e(TAG, "Критическая ошибка в triggerAllRewardListeners: " + t.getMessage(), t);
                }
            }
        });
    }

    private static Object getUnityFinishStateEnum(Class<?> enumClass) {
        if (enumClass == null || !enumClass.isEnum()) return null;
        for (Object constant : enumClass.getEnumConstants()) {
            if ("COMPLETED".equalsIgnoreCase(constant.toString())) {
                return constant;
            }
        }
        Object[] constants = enumClass.getEnumConstants();
        return (constants != null && constants.length > 0) ? constants[0] : null;
    }

    private static Object createFakeRewardProxy(Class<?> interfaceClass) {
        if (interfaceClass == null || !interfaceClass.isInterface()) return null;
        try {
            return Proxy.newProxyInstance(
                interfaceClass.getClassLoader(),
                new Class<?>[]{interfaceClass},
                new InvocationHandler() {
                    @Override
                    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
                        String mName = method.getName();
                        if ("getAmount".equals(mName)) return 1;
                        if ("getType".equals(mName)) return "reward";
                        if ("toString".equals(mName)) return "SmartReward[Amount=1, Type=reward]";
                        return null;
                    }
                }
            );
        } catch (Throwable t) {
            Log.d(TAG, "FakeRewardProxy note: " + t.getMessage());
            return null;
        }
    }

    private static Object createFakeResponseInfoProxy(Class<?> interfaceClass) {
        if (interfaceClass == null || !interfaceClass.isInterface()) return null;
        try {
            return Proxy.newProxyInstance(
                interfaceClass.getClassLoader(),
                new Class<?>[]{interfaceClass},
                new InvocationHandler() {
                    @Override
                    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
                        String mName = method.getName();
                        if ("getAdapterResponses".equals(mName)) return Collections.emptyList();
                        if ("getLoadedAdapterResponseInfo".equals(mName)) return null;
                        if ("getResponseId".equals(mName)) return "smart_reward_response_id";
                        if ("getMediationAdapterClassName".equals(mName)) return "SmartRewardMediationAdapter";
                        if ("toString".equals(mName)) return "SmartRewardFakeResponseInfo[Status=SUCCESS]";
                        return null;
                    }
                }
            );
        } catch (Throwable t) {
            Log.d(TAG, "FakeResponseInfoProxy note: " + t.getMessage());
            return null;
        }
    }

    private static void notifyUnityRewardCallbacks() {
        String ironJson = "{\"placement_name\":\"DefaultRewardedVideo\",\"reward_name\":\"coins\",\"reward_amount\":\"1\"}";
        boolean sentViaJava = false;

        try {
            ClassLoader cl = getAppClassLoader();
            Class<?> unityPlayer = cl.loadClass("com.unity3d.player.UnityPlayer");
            Method sendMsg = unityPlayer.getDeclaredMethod("UnitySendMessage", String.class, String.class, String.class);
            sendMsg.setAccessible(true);

            Set<String> unitsToNotify = new HashSet<>(sKnownAdUnitIds);
            if (unitsToNotify.isEmpty()) {
                unitsToNotify.add("default_rewarded");
            }

            for (String adUnitId : unitsToNotify) {
                DynamicAdMeta meta = sDynamicAdMetaMap.get(adUnitId);
                String creativeId = (meta != null) ? meta.getCreativeIdentifier() : ("cr_" + Long.toHexString((System.currentTimeMillis() ^ (long) adUnitId.hashCode()) & 0xFFFFFFFFL));
                String netPlacement = (meta != null && !meta.networkPlacement.isEmpty()) ? meta.networkPlacement : "";
                String placement = meta != null ? meta.placement : "";
                String netName = (meta != null && !meta.networkName.isEmpty()) ? meta.networkName : "AppLovin";
                String rLabel = (meta != null && !meta.rewardLabel.isEmpty()) ? meta.rewardLabel : "";
                double rAmt = (meta != null && meta.rewardAmount > 0) ? meta.rewardAmount : 1.0;
                double rev = (meta != null && meta.revenue > 0) ? meta.revenue : 0.05;

                String displayedJson = "{\"name\":\"OnRewardedAdDisplayedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\"}}";
                String rewardJson = "{\"name\":\"OnRewardedAdReceivedRewardEvent\",\"adUnitId\":\"" + adUnitId + "\",\"rewardLabel\":\"" + rLabel + "\",\"rewardAmount\":" + rAmt + ",\"reward\":{\"label\":\"" + rLabel + "\",\"amount\":" + rAmt + "},\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";
                String hiddenJson = "{\"name\":\"OnRewardedAdHiddenEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\"}}";
                String loadedJson = "{\"name\":\"OnRewardedAdLoadedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"" + netName + "\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"" + netName + "\",\"networkPlacement\":\"" + netPlacement + "\",\"placement\":\"" + placement + "\",\"creativeIdentifier\":\"" + creativeId + "\",\"revenue\":" + rev + ",\"revenuePrecision\":\"exact\"}}";

                try {
                    sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", displayedJson);
                    sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", rewardJson);
                    sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", hiddenJson);
                    sendMsg.invoke(null, "MaxSdkCallbacks", "ForwardEvent", loadedJson);
                } catch (Throwable t) { Log.d(TAG, "MaxSdk UnitySendMessage note: " + t.getMessage()); }
            }

            try {
                sendMsg.invoke(null, "GoogleMobileAdsCallbacks", "onRewardedAdLoaded", "");
                sendMsg.invoke(null, "GoogleMobileAdsCallbacks", "onAdShowedFullScreenContent", "");
                sendMsg.invoke(null, "GoogleMobileAdsCallbacks", "onUserEarnedReward", "{\"type\":\"coins\",\"amount\":1}");
                sendMsg.invoke(null, "GoogleMobileAdsCallbacks", "onUserEarnedReward", "1");
                sendMsg.invoke(null, "GoogleMobileAdsCallbacks", "onAdDismissedFullScreenContent", "");
                sendMsg.invoke(null, "GoogleMobileAdsCallbacks", "onRewardedAdClosed", "");

                sendMsg.invoke(null, "GoogleMobileAdsRewardedAdClient", "onAdShowedFullScreenContent", "");
                sendMsg.invoke(null, "GoogleMobileAdsRewardedAdClient", "onUserEarnedReward", "{\"type\":\"coins\",\"amount\":1}");
                sendMsg.invoke(null, "GoogleMobileAdsRewardedAdClient", "onUserEarnedReward", "1");
                sendMsg.invoke(null, "GoogleMobileAdsRewardedAdClient", "onAdDismissedFullScreenContent", "");
            } catch (Throwable t) { Log.d(TAG, "Google UnitySendMessage note: " + t.getMessage()); }

            try {
                sendMsg.invoke(null, "YandexMobileAdsCallback", "OnAdShown", "");
                sendMsg.invoke(null, "YandexMobileAdsRewardCallback", "OnRewarded", "{\"amount\":1,\"type\":\"coins\"}");
                sendMsg.invoke(null, "YandexMobileAdsRewardCallback", "OnRewarded", "1");
                sendMsg.invoke(null, "YandexMobileAdsCallback", "OnAdDismissed", "");
                sendMsg.invoke(null, "YandexMobileAdsCallback", "OnAdLoaded", "");
            } catch (Throwable t) { Log.d(TAG, "Yandex UnitySendMessage note: " + t.getMessage()); }

            try {
                sendMsg.invoke(null, "IronSourceEvents", "onRewardedVideoAvailabilityChanged", "{\"available\":\"true\"}");
                sendMsg.invoke(null, "IronSourceEvents", "onRewardedVideoAdOpened", "");
                sendMsg.invoke(null, "IronSourceEvents", "onRewardedVideoAdRewarded", ironJson);
                sendMsg.invoke(null, "IronSourceEvents", "onRewardedVideoAdClosed", "");
                sendMsg.invoke(null, "IronSourceEvents", "onRewardedVideoAvailabilityChanged", "{\"available\":\"true\"}");
            } catch (Throwable t) { Log.d(TAG, "IronSource UnitySendMessage note: " + t.getMessage()); }

            try {
                sendMsg.invoke(null, "UnityAdsCallbacks", "onUnityAdsAdLoaded", "rewardedVideo");
                sendMsg.invoke(null, "UnityAdsCallbacks", "onUnityAdsShowStart", "rewardedVideo");
                sendMsg.invoke(null, "UnityAdsCallbacks", "onUnityAdsShowComplete", "{\"placementId\":\"rewardedVideo\",\"showCompletionState\":\"COMPLETED\"}");
                sendMsg.invoke(null, "UnityAdsCallbacks", "onUnityAdsFinish", "rewardedVideo;COMPLETED");
                sendMsg.invoke(null, "UnityAdsCallbacks", "onUnityAdsAdLoaded", "rewardedVideo");
            } catch (Throwable t) { Log.d(TAG, "UnityAds UnitySendMessage note: " + t.getMessage()); }

            try {
                sendMsg.invoke(null, "RewardedVideoAdBridge", "onRewardedVideoCompleted", "");
                sendMsg.invoke(null, "RewardedVideoAdBridge", "onRewardServerSuccess", "");
                sendMsg.invoke(null, "RewardedVideoAdBridge", "onRewardedVideoClosed", "");
                sendMsg.invoke(null, "AudienceNetworkCallbackAndroid", "onRewardedVideoCompleted", "");
                sendMsg.invoke(null, "AudienceNetworkCallbackAndroid", "onRewardServerSuccess", "");
                sendMsg.invoke(null, "AudienceNetworkCallbackAndroid", "onRewardedVideoClosed", "");
            } catch (Throwable t) { Log.d(TAG, "AudienceNetwork UnitySendMessage note: " + t.getMessage()); }

            try {
                sendMsg.invoke(null, "MBridgeRewardCallbacks", "onVideoComplete", "");
                sendMsg.invoke(null, "MBridgeRewardCallbacks", "onAdCloseWithReward", "{\"rewardName\":\"coins\",\"rewardAmount\":1}");
                sendMsg.invoke(null, "VungleCallbacks", "onAdReward", "rewardedVideo");
                sendMsg.invoke(null, "VungleCallbacks", "onAdEnd", "rewardedVideo");
                sendMsg.invoke(null, "PAGRewardedAdCallbacks", "onUserEarnedReward", "");
                sendMsg.invoke(null, "PAGRewardedAdCallbacks", "onAdDismissed", "");
                sendMsg.invoke(null, "MobileAdsHandler", "OnRewardedAdReceivedRewardEvent", "");
                sendMsg.invoke(null, "MobileAdsHandler", "OnRewardedAdHiddenEvent", "");
            } catch (Throwable t) { Log.d(TAG, "Additional SDK UnitySendMessage note: " + t.getMessage()); }

            sentViaJava = true;
            Log.i(TAG, "UnitySendMessage: эвенты наград успешно переданы в UnityPlayer через Java Reflection");
        } catch (Throwable t) {
            Log.d(TAG, "UnityPlayer Java Reflection not available: " + t.getMessage());
        }

        // Дедупликация: нативный JNI мост используется только если Java reflection недоступен
        if (!sentViaJava) {
            try {
                for (String adUnitId : sKnownAdUnitIds) {
                    String rewardJson = "{\"name\":\"OnRewardedAdReceivedRewardEvent\",\"adUnitId\":\"" + adUnitId + "\",\"rewardLabel\":\"coins\",\"rewardAmount\":1,\"networkName\":\"AppLovin\"}";
                    nativeNotifyUnityReward("MaxSdkCallbacks", "ForwardEvent", rewardJson);
                }
                nativeNotifyUnityReward("GoogleMobileAdsCallbacks", "onUserEarnedReward", "1");
                nativeNotifyUnityReward("YandexMobileAdsRewardCallback", "OnRewarded", "1");
                nativeNotifyUnityReward("IronSourceEvents", "onRewardedVideoAvailabilityChanged", "{\"available\":\"true\"}");
                nativeNotifyUnityReward("IronSourceEvents", "onRewardedVideoAdRewarded", ironJson);
                nativeNotifyUnityReward("IronSourceEvents", "onRewardedVideoAvailabilityChanged", "{\"available\":\"true\"}");
                nativeNotifyUnityReward("UnityAdsCallbacks", "onUnityAdsShowComplete", "rewardedVideo");
                nativeNotifyUnityReward("RewardedVideoAdBridge", "onRewardedVideoCompleted", "");
                nativeNotifyUnityReward("AudienceNetworkCallbackAndroid", "onRewardedVideoCompleted", "");
                nativeNotifyUnityReward("MBridgeRewardCallbacks", "onVideoComplete", "");
                nativeNotifyUnityReward("VungleCallbacks", "onAdReward", "");
                nativeNotifyUnityReward("PAGRewardedAdCallbacks", "onUserEarnedReward", "");
                Log.i(TAG, "UnitySendMessage: эвенты наград успешно переданы через Native JNI Bridge");
            } catch (Throwable t) {
                Log.d(TAG, "Native UnitySendMessage JNI note: " + t.getMessage());
            }
        }
    }

    private static void attachBannerCollapser(final Activity activity) {
        if (activity == null || isStrictAdActivity(activity) || sBannerCollapserAttached.contains(activity)) return;
        try {
            final View decor = activity.getWindow().getDecorView();
            if (decor == null) return;

            sBannerCollapserAttached.add(activity);
            decor.getViewTreeObserver().addOnGlobalLayoutListener(new ViewTreeObserver.OnGlobalLayoutListener() {
                @Override
                public void onGlobalLayout() {
                    collapseBannerViews(decor);
                }
            });
        } catch (Throwable t) {
            Log.d(TAG, "BannerCollapser attach note: " + t.getMessage());
        }
    }

    private static final Set<View> sCollapsedViews = Collections.synchronizedSet(
            Collections.newSetFromMap(new WeakHashMap<View, Boolean>()));

    private static void collapseBannerViews(View view) {
        if (view == null) return;
        if (sCollapsedViews.contains(view) && view.getVisibility() == View.GONE) return;

        String clsName = view.getClass().getName();
        if (AD_SURFACE_CLASSES.contains(clsName)) {
            if (view.getVisibility() != View.GONE) {
                view.setVisibility(View.GONE);
            }
            ViewGroup.LayoutParams lp = view.getLayoutParams();
            if (lp != null && (lp.width != 0 || lp.height != 0)) {
                lp.width = 0;
                lp.height = 0;
                view.setLayoutParams(lp);
            }
            sCollapsedViews.add(view);
            return;
        }
        if (view instanceof ViewGroup) {
            ViewGroup vg = (ViewGroup) view;
            int childCount = Math.min(vg.getChildCount(), 20);
            for (int i = 0; i < childCount; i++) {
                collapseBannerViews(vg.getChildAt(i));
            }
        }
    }
}
