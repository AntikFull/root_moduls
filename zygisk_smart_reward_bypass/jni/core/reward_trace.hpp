#pragma once

#include <string>
#include <vector>
#include <deque>
#include <unordered_map>
#include <mutex>
#include <cstdint>

namespace smartreward {

// Этапы жизненного цикла наград (для совместимости и прогресса)
enum class RewardStage {
    ProcessDetected,
    EngineDetected,
    RuntimeReady,
    SdkDetected,
    RewardObjectFound,
    PlacementResolved,
    ShowObserved,
    ListenerResolved,
    AdDisplayed,
    CompletionObserved,
    RewardCallbackObserved,
    AppHandlerObserved,
    Finished
};

// Состояния рекламного объекта (AdState Reducer)
enum class AdState {
    Unknown,
    SdkUnavailable,
    SdkInitializing,
    ObjectMissing,
    Idle,
    Loading,
    Loaded,
    Ready,
    Showing,
    Completed,
    Failed
};

// События жизненного цикла для Reducer
enum class LifecycleEvent {
    LoadRequested,
    LoadSuccess,
    ReadyObserved,
    ReadyOverrideApplied,
    ShowRequested,
    Displayed,
    Completed,
    RewardGranted,
    Failed
};

// Происхождение сигнала готовности (ReadyOrigin)
enum class ReadyOrigin {
    Sdk,
    GameWrapper,
    UiGate,
    Unknown
};

// Транспорт доставки события готовности (ReadyTransport)
enum class ReadyTransport {
    Native,
    Il2Cpp,
    Jni,
    Java,
    Unknown
};

// Классификация событий готовности (ReadyEventType)
enum class ReadyEventType {
    Observed,          // Реальное неизмененное значение метода
    OverrideApplied,   // Установлен хук подмены (test/override)
    Lifecycle          // Событие жизненного цикла (Loaded/Displayed)
};

// Причины сбоя на каждом звене цепочки наград
enum class RewardFailure {
    None,
    UnsupportedEngine,
    RuntimeNotLoaded,
    RuntimeInitTimeout,
    SdkNotDetected,
    SdkVersionUnknown,
    BackendUnavailable,
    RewardObjectNotFound,
    MethodNotFound,
    SignatureMismatch,
    AbiUnsafe,
    ListenerNotFound,
    ListenerInstalledLate,
    ShowNotObserved,
    DisplayCallbackMissing,
    CompletionCallbackMissing,
    RewardCallbackMissing,
    AppHandlerMissing,
    PlacementUnknown,
    ContextLost,
    ContextCollision,
    SecondaryProcessIgnored,
    TargetFiltered,
    ServerSideValidationLikely,
    InternalError
};

// Причины неготовности рекламы
enum class NotReadyReason {
    Unknown,
    NotLoaded,
    LoadNotStarted,
    LoadInProgress,
    LoadFailed,
    NoNetwork,
    NoFill,
    SdkNotInitialized,
    ConsentRequired,
    PlacementInvalid,
    Cooldown,
    FrequencyCap,
    BackendUnavailable,
    ObjectNotFound,
    CallbackMissing
};

// Независимые факты жизненного цикла
struct RewardFacts {
    bool fact_process_detected = false;
    bool fact_engine_detected = false;
    bool fact_runtime_ready = false;
    bool fact_sdk_detected = false;
    bool fact_show_observed = false;
    bool fact_display_observed = false;
    bool fact_completion_observed = false;
    bool fact_reward_observed = false;
    bool fact_failed = false;

    uint64_t ts_show_ms = 0;
    uint64_t ts_display_ms = 0;
    uint64_t ts_completion_ms = 0;
    uint64_t ts_reward_ms = 0;
    uint64_t ts_failed_ms = 0;
};

// Трассировка попытки показа и начисления награды
struct RewardTrace {
    uint64_t id = 0;
    std::string package_name;
    std::string process_name;
    std::string engine;
    std::string sdk;
    std::string placement;
    uintptr_t rewarded_object = 0;
    uint64_t steady_started_ms = 0;
    uint64_t steady_last_event_ms = 0;
    uint64_t wall_started_ms = 0;
    AdState ad_state = AdState::Unknown;
    RewardStage highest_stage = RewardStage::ProcessDetected;
    RewardStage failed_at_stage = RewardStage::ProcessDetected;
    RewardFailure failure = RewardFailure::None;
    int confidence = 0;
    RewardFacts facts;
    std::vector<std::string> event_log;
};

// Трассировка проверки готовности v2 (с точным ключом и Coalesce-окном)
struct ReadyTrace {
    uint64_t trace_id = 0;
    uintptr_t object = 0;
    std::string sdk;
    std::string format;
    std::string placement;
    std::string class_name;
    std::string method_name;
    ReadyEventType event_type = ReadyEventType::Observed;
    ReadyOrigin origin = ReadyOrigin::Sdk;
    ReadyTransport transport = ReadyTransport::Native;
    int8_t observed_value = -1;  // -1 = unknown, 0 = false, 1 = true
    int8_t effective_value = -1; // -1 = unknown, 0 = false, 1 = true
    uint64_t first_seen_ms = 0;
    uint64_t last_seen_ms = 0;
    uint32_t count = 1;
    NotReadyReason reason = NotReadyReason::Unknown;
    int confidence = 100;
};

// Менеджер машины состояний и телеметрии наград (Потокобезопасный с Reducer и Smart Eviction)
class RewardTraceManager {
public:
    static RewardTraceManager &instance();

    // Управление Trace наград
    uint64_t start_trace(const std::string &package, const std::string &process,
                         const std::string &engine, const std::string &sdk,
                         const std::string &placement, uintptr_t obj_ptr, int confidence = 100);

    // Централизованный State Reducer
    void apply_event(uint64_t trace_id, LifecycleEvent event,
                     RewardFailure failure = RewardFailure::None,
                     const std::string &detail = "");

    void record_stage(uint64_t trace_id, RewardStage stage,
                      RewardFailure failure = RewardFailure::None,
                      const std::string &detail = "");

    uint64_t correlate_trace(uintptr_t obj_ptr, const std::string &placement, const std::string &sdk);

    void print_reward_summary(uint64_t trace_id) const;

    // Управление Readiness проверками (с агрегацией в окне 2000 мс)
    void record_ready_check(const ReadyTrace &ready);
    void print_readiness_summary() const;

    // Экспорт в JSON (публичный потокобезопасный метод)
    std::string to_json_summary() const;

    // Хелперы преобразования в текст
    static const char *to_string(RewardStage stage);
    static const char *to_string(AdState state);
    static const char *to_string(ReadyOrigin origin);
    static const char *to_string(ReadyTransport transport);
    static const char *to_string(ReadyEventType event_type);
    static const char *to_string(RewardFailure failure);
    static const char *to_string(NotReadyReason reason);
    static const char *val_to_string(int8_t val);

private:
    RewardTraceManager() = default;
    mutable std::mutex mutex_;
    uint64_t next_trace_id_ = 1000;
    static constexpr size_t MAX_TRACES = 50;
    static constexpr size_t MAX_READY_CHECKS = 100;
    static constexpr size_t MAX_EVENT_LOG = 20;
    static constexpr uint64_t COALESCE_WINDOW_MS = 2000;

    std::deque<uint64_t> trace_order_;
    std::unordered_map<uint64_t, RewardTrace> traces_;
    std::vector<ReadyTrace> ready_checks_;

    void evict_oldest_trace_locked();
    void print_reward_summary_locked(uint64_t trace_id) const;
    std::string to_json_summary_locked() const;
};

} // namespace smartreward
