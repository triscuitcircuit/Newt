#include "Newt/Session.h"
#include "CoreInternal.h"
#include "include/NewtLog.h"
#include <algorithm>
#include <cstring>
#include <thread>
using namespace NewtInternal;
using Newt::Session;
void Session::CreateActions() {
    mHandPaths[0] = MakePath(mInstance, "/user/hand/left");
    mHandPaths[1] = MakePath(mInstance, "/user/hand/right");

    XrActionSetCreateInfo asci{ XR_TYPE_ACTION_SET_CREATE_INFO };
    std::strncpy(asci.actionSetName, "newt", XR_MAX_ACTION_SET_NAME_SIZE - 1);
    std::strncpy(asci.localizedActionSetName, "Newt", XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
    CheckXr(xrCreateActionSet(mInstance, &asci, &mActionSet), "xrCreateActionSet");

    auto makeAction = [&](XrActionType type, const char* name, const char* localized,
                          XrAction* out) {
        XrActionCreateInfo aci{ XR_TYPE_ACTION_CREATE_INFO };
        aci.actionType = type;
        std::strncpy(aci.actionName, name, XR_MAX_ACTION_NAME_SIZE - 1);
        std::strncpy(aci.localizedActionName, localized, XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
        aci.countSubactionPaths = 2;
        aci.subactionPaths = mHandPaths.data();
        CheckXr(xrCreateAction(mActionSet, &aci, out), "xrCreateAction");
    };
    makeAction(XR_ACTION_TYPE_POSE_INPUT, "aim", "Aim Pose", &mAimAction);
    makeAction(XR_ACTION_TYPE_FLOAT_INPUT, "grab", "Move Screen", &mGrabAction);
    makeAction(XR_ACTION_TYPE_POSE_INPUT, "grip", "Grip Pose", &mGripAction);
    makeAction(XR_ACTION_TYPE_BOOLEAN_INPUT, "select", "Select", &mSelectAction);
    makeAction(XR_ACTION_TYPE_BOOLEAN_INPUT, "menu", "Menu", &mMenuAction);
    makeAction(XR_ACTION_TYPE_VECTOR2F_INPUT, "thumbstick", "Thumbstick", &mThumbstickAction);
    makeAction(XR_ACTION_TYPE_VIBRATION_OUTPUT, "haptic", "Haptic Feedback", &mHapticAction);
    makeAction(XR_ACTION_TYPE_FLOAT_INPUT, "trigger_value", "Trigger", &mTriggerAction);
    makeAction(XR_ACTION_TYPE_BOOLEAN_INPUT, "primary_button", "Primary Button", &mPrimaryAction);
    makeAction(XR_ACTION_TYPE_BOOLEAN_INPUT, "secondary_button", "Secondary Button", &mSecondaryAction);
    makeAction(XR_ACTION_TYPE_BOOLEAN_INPUT, "stick_click", "Thumbstick Click", &mStickClickAction);
    makeAction(XR_ACTION_TYPE_BOOLEAN_INPUT, "menu_click", "Menu Button", &mMenuClickAction);

    std::vector<XrActionSuggestedBinding> bindings;
    auto bind = [&](XrAction action, const char* path) {
        XrActionSuggestedBinding b{};
        b.action = action;
        b.binding = MakePath(mInstance, path);
        bindings.push_back(b);
    };
    bind(mAimAction, "/user/hand/left/input/aim/pose");
    bind(mAimAction, "/user/hand/right/input/aim/pose");
    bind(mGripAction, "/user/hand/left/input/grip/pose");
    bind(mGripAction, "/user/hand/right/input/grip/pose");
    bind(mSelectAction, "/user/hand/left/input/trigger/value");
    bind(mSelectAction, "/user/hand/right/input/trigger/value");
    bind(mSelectAction, "/user/hand/left/input/x/click");
    bind(mSelectAction, "/user/hand/right/input/a/click");
    bind(mSelectAction, "/user/hand/left/input/thumbstick/click");
    bind(mSelectAction, "/user/hand/right/input/thumbstick/click");
    bind(mGrabAction, "/user/hand/left/input/squeeze/value");
    bind(mGrabAction, "/user/hand/right/input/squeeze/value");
    bind(mMenuAction, "/user/hand/left/input/menu/click");
    bind(mMenuAction, "/user/hand/right/input/system/click");
    bind(mMenuAction, "/user/hand/left/input/y/click");
    bind(mMenuAction, "/user/hand/right/input/b/click");
    bind(mThumbstickAction, "/user/hand/left/input/thumbstick");
    bind(mThumbstickAction, "/user/hand/right/input/thumbstick");
    bind(mTriggerAction, "/user/hand/left/input/trigger/value");
    bind(mTriggerAction, "/user/hand/right/input/trigger/value");
    bind(mPrimaryAction, "/user/hand/left/input/x/click");
    bind(mPrimaryAction, "/user/hand/right/input/a/click");
    bind(mSecondaryAction, "/user/hand/left/input/y/click");
    bind(mSecondaryAction, "/user/hand/right/input/b/click");
    bind(mStickClickAction, "/user/hand/left/input/thumbstick/click");
    bind(mStickClickAction, "/user/hand/right/input/thumbstick/click");
    bind(mMenuClickAction, "/user/hand/left/input/menu/click");
    bind(mHapticAction, "/user/hand/left/output/haptic");
    bind(mHapticAction, "/user/hand/right/output/haptic");

    XrInteractionProfileSuggestedBinding suggested{ XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING };
    suggested.interactionProfile = MakePath(mInstance, "/interaction_profiles/oculus/touch_controller");
    suggested.countSuggestedBindings = static_cast<uint32_t>(bindings.size());
    suggested.suggestedBindings = bindings.data();
    CheckXr(xrSuggestInteractionProfileBindings(mInstance, &suggested),
            "xrSuggestInteractionProfileBindings");

    for (int i = 0; i < 2; ++i) {
        XrActionSpaceCreateInfo sci{ XR_TYPE_ACTION_SPACE_CREATE_INFO };
        sci.action = mAimAction;
        sci.subactionPath = mHandPaths[i];
        sci.poseInActionSpace = IdentityPose();
        CheckXr(xrCreateActionSpace(mSession, &sci, &mAimSpaces[i]), "xrCreateActionSpace(aim)");
        sci.action = mGripAction;
        CheckXr(xrCreateActionSpace(mSession, &sci, &mGripSpaces[i]), "xrCreateActionSpace(grip)");
    }

    XrSessionActionSetsAttachInfo attach{ XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO };
    attach.countActionSets = 1;
    attach.actionSets = &mActionSet;
    CheckXr(xrAttachSessionActionSets(mSession, &attach), "xrAttachSessionActionSets");
}

void Session::CreateHandTrackers() {
    if (!mHandTrackingSupported) {
        Newt_Logf(NEWT_LOG_INFO, "Hand tracking unavailable; wrist clock requires tracked hands");
        return;
    }
    if (XR_FAILED(xrGetInstanceProcAddr(mInstance, "xrCreateHandTrackerEXT", reinterpret_cast<PFN_xrVoidFunction*>(&mCreateHandTracker))) ||
        XR_FAILED(xrGetInstanceProcAddr(mInstance, "xrDestroyHandTrackerEXT", reinterpret_cast<PFN_xrVoidFunction*>(&mDestroyHandTracker))) ||
        XR_FAILED(xrGetInstanceProcAddr(mInstance, "xrLocateHandJointsEXT", reinterpret_cast<PFN_xrVoidFunction*>(&mLocateHandJoints))) ||
        !mCreateHandTracker || !mDestroyHandTracker || !mLocateHandJoints) return;
    for (int hand = 0; hand < 2; ++hand) {
        XrHandTrackerCreateInfoEXT info{XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT};
        info.hand = hand == 0 ? XR_HAND_LEFT_EXT : XR_HAND_RIGHT_EXT;
        info.handJointSet = XR_HAND_JOINT_SET_DEFAULT_EXT;
        const auto result = mCreateHandTracker(mSession, &info, &mHandTrackers[hand]);
        if (XR_FAILED(result)) {
            mHandTrackers[hand] = XR_NULL_HANDLE;
            Newt_Logf(NEWT_LOG_WARNING, "Hand tracker %d unavailable (%d)", hand, result);
        }
    }
}

bool Session::PollEvents() {
    XrEventDataBuffer event{ XR_TYPE_EVENT_DATA_BUFFER };
    while (xrPollEvent(mInstance, &event) == XR_SUCCESS) {
        switch (event.type) {
        case XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED: {
            const auto* e = reinterpret_cast<const XrEventDataSessionStateChanged*>(&event);
            if (e->session != XR_NULL_HANDLE && e->session != mSession) break;
            mSessionState = e->state;
            mDelegate->OnSessionState(mSessionState);
            switch (mSessionState) {
            case XR_SESSION_STATE_READY: {
                XrSessionBeginInfo bi{ XR_TYPE_SESSION_BEGIN_INFO };
                SetPrimaryViewType(bi, mViewType);
                CheckXr(xrBeginSession(mSession, &bi), "xrBeginSession");
                mSessionRunning = true;
                Newt_Logf(NEWT_LOG_INFO, "session running.");
                break;
            }
            case XR_SESSION_STATE_STOPPING:
                CheckXr(xrEndSession(mSession), "xrEndSession");
                mSessionRunning = false;
                break;
            case XR_SESSION_STATE_EXITING:
            case XR_SESSION_STATE_LOSS_PENDING:
                return true;
            default:
                break;
            }
            break;
        }
        case XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING:
            return true;
        default:
            break;
        }
        event.type = XR_TYPE_EVENT_DATA_BUFFER;
    }
    return false;
}

bool Session::LocatePose(XrSpace space, XrTime time, XrPosef& pose) {
    XrSpaceLocation loc{ XR_TYPE_SPACE_LOCATION };
    CheckXr(xrLocateSpace(space, mAppSpace, time, &loc), "xrLocateSpace");
    const bool valid =
        (loc.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT) != 0 &&
        (loc.locationFlags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT) != 0;
    if (valid) pose = loc.pose;
    return valid;
}

void Session::PulseHaptic(int hand, float amplitude) {
    if (mSessionState != XR_SESSION_STATE_FOCUSED) return;
    XrHapticVibration vibration{XR_TYPE_HAPTIC_VIBRATION};
    vibration.duration = XR_MIN_HAPTIC_DURATION;
    vibration.frequency = XR_FREQUENCY_UNSPECIFIED;
    vibration.amplitude = std::clamp(amplitude, 0.0f, 1.0f);
    XrHapticActionInfo info{XR_TYPE_HAPTIC_ACTION_INFO};
    info.action = mHapticAction;
    info.subactionPath = mHandPaths[hand];
    xrApplyHapticFeedback(mSession, &info, reinterpret_cast<const XrHapticBaseHeader*>(&vibration));
}

Newt::InputState Session::ReadInput(XrTime time) {
    Newt::InputState input; input.displayTime = time;
    if (mSessionState != XR_SESSION_STATE_FOCUSED) return input;
    input.focused = true;
    XrActiveActionSet active{mActionSet, XR_NULL_PATH};
    XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};
    sync.countActiveActionSets = 1; sync.activeActionSets = &active;
    CheckXr(xrSyncActions(mSession, &sync), "xrSyncActions");
    XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO};
    locate.viewConfigurationType=mViewType; locate.displayTime=time; locate.space=mAppSpace;
    XrViewState state{XR_TYPE_VIEW_STATE};
    std::vector<XrView> views(mViewConfigs.size(), {XR_TYPE_VIEW}); uint32_t count=0;
    if (XR_SUCCEEDED(xrLocateViews(mSession,&locate,&state,views.size(),&count,views.data())) && count > 0 &&
        (state.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) && (state.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT)) {
        input.viewerValid = true; input.viewer=views[0].pose;
        input.viewer.position={0,0,0};
        for(uint32_t i=0;i<count;++i) {
            input.viewer.position.x+=views[i].pose.position.x/count;
            input.viewer.position.y+=views[i].pose.position.y/count;
            input.viewer.position.z+=views[i].pose.position.z/count;
        }
    }
    for(int hand=0;hand<2;++hand) {
        if (mHandTrackers[hand] != XR_NULL_HANDLE && mLocateHandJoints) {
            std::array<XrHandJointLocationEXT, XR_HAND_JOINT_COUNT_EXT> joints{};
            XrHandJointLocationsEXT locations{XR_TYPE_HAND_JOINT_LOCATIONS_EXT};
            locations.jointCount = static_cast<uint32_t>(joints.size());
            locations.jointLocations = joints.data();
            XrHandJointsLocateInfoEXT info{XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT};
            info.baseSpace = mAppSpace;
            info.time = time;
            constexpr XrSpaceLocationFlags required = XR_SPACE_LOCATION_POSITION_VALID_BIT |
                XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_TRACKED_BIT |
                XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT;
            if (XR_SUCCEEDED(mLocateHandJoints(mHandTrackers[hand], &info, &locations)) && locations.isActive &&
                (joints[XR_HAND_JOINT_PALM_EXT].locationFlags & required) == required &&
                (joints[XR_HAND_JOINT_WRIST_EXT].locationFlags & required) == required) {
                input.handValid[hand] = true;
                input.palm[hand] = joints[XR_HAND_JOINT_PALM_EXT].pose;
                input.wrist[hand] = joints[XR_HAND_JOINT_WRIST_EXT].pose;
                input.jointsValid[hand] = std::all_of(joints.begin(), joints.end(), [&](const XrHandJointLocationEXT& j) {
                    return (j.locationFlags & required) == required;
                });
                if (input.jointsValid[hand])
                    for (size_t j = 0; j < joints.size(); ++j) input.joints[hand][j] = joints[j].pose;
            }
        }
        input.aimValid[hand]=LocatePose(mAimSpaces[hand],time,input.aim[hand]);
        input.gripValid[hand]=LocatePose(mGripSpaces[hand],time,input.grip[hand]);
        XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO}; get.subactionPath=mHandPaths[hand];
        auto button=[&](XrAction action) {
            get.action=action; XrActionStateBoolean value{XR_TYPE_ACTION_STATE_BOOLEAN};
            CheckXr(xrGetActionStateBoolean(mSession,&get,&value),"xrGetActionStateBoolean");
            return value.isActive && value.currentState;
        };
        input.select[hand]=button(mSelectAction); input.menu[hand]=button(mMenuAction);
        auto rawButton = [&](XrAction action, XrActionStateBoolean& value) {
            get.action = action; value.type = XR_TYPE_ACTION_STATE_BOOLEAN;
            CheckXr(xrGetActionStateBoolean(mSession, &get, &value), "xrGetActionStateBoolean");
        };
        rawButton(mPrimaryAction, input.primary[hand]);
        rawButton(mSecondaryAction, input.secondary[hand]);
        rawButton(mStickClickAction, input.stickClick[hand]);
        rawButton(mMenuClickAction, input.menuClick[hand]);
        get.action=mTriggerAction; input.trigger[hand].type=XR_TYPE_ACTION_STATE_FLOAT;
        CheckXr(xrGetActionStateFloat(mSession,&get,&input.trigger[hand]),"xrGetActionStateFloat(trigger)");
        get.action=mGrabAction; input.grab[hand].type=XR_TYPE_ACTION_STATE_FLOAT;
        CheckXr(xrGetActionStateFloat(mSession,&get,&input.grab[hand]),"xrGetActionStateFloat");
        get.action=mThumbstickAction; input.stick[hand].type=XR_TYPE_ACTION_STATE_VECTOR2F;
        CheckXr(xrGetActionStateVector2f(mSession,&get,&input.stick[hand]),"xrGetActionStateVector2f");
    }
    return input;
}
