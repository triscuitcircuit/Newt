// SPDX-License-Identifier: MIT



#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <sys/file.h>
#include <csignal>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <launch.h>
#include <poll.h>
#include <spawn.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr NSUInteger kMaxMessage = 65536;

struct NewtError {
    std::string message;
};

[[noreturn]] void Fail(const std::string& message) { throw NewtError{message}; }

std::string Str(NSString* value) { return value != nil ? std::string([value UTF8String] ?: "") : ""; }
NSString* NStr(const std::string& value) { return [NSString stringWithUTF8String:value.c_str()] ?: @""; }

NSString* PrivateDir(NSString* path) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSError* error = nil;
    if (![fm createDirectoryAtPath:path
       withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0700}
                             error:&error]) {
        // Existing directory is fine; anything else is fatal below.
    }
    struct stat st {};
    if (::lstat([path fileSystemRepresentation], &st) != 0 || !S_ISDIR(st.st_mode) ||
        st.st_uid != ::getuid() || (st.st_mode & 0077) != 0) {
        Fail("Expected a private, user-owned directory: " + Str(path));
    }
    return path;
}

struct Paths {
    NSString* state;
    NSString* endpoint;
};

Paths GetPaths() {
    NSDictionary<NSString*, NSString*>* env = NSProcessInfo.processInfo.environment;
    NSString* stateValue = env[@"NEWT_STATE_DIR"];
    if (stateValue.length == 0) {
        stateValue = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
    }
    NSString* ipcValue = env[@"NEWT_IPC_DIR"];
    if (ipcValue.length == 0) {
        ipcValue = [NSString stringWithFormat:@"/tmp/newt-session-%d", ::getuid()];
    }
    Paths paths;
    paths.state = PrivateDir(stateValue);
    paths.endpoint = [PrivateDir(ipcValue) stringByAppendingPathComponent:@"session.sock"];
    return paths;
}

NSData* JsonData(id object) {
    NSError* error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (data == nil) Fail("Could not encode JSON: " + Str(error.localizedDescription));
    return data;
}

id ParseJson(NSData* data) {
    NSError* error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (value == nil) Fail("Invalid JSON: " + Str(error.localizedDescription));
    return value;
}

NSString* ResolveStrict(NSString* path) {
    NSString* resolved = path.stringByResolvingSymlinksInPath;
    if (![NSFileManager.defaultManager fileExistsAtPath:resolved]) {
        Fail("No such file or directory: " + Str(path));
    }
    char real[PATH_MAX];
    if (::realpath([resolved fileSystemRepresentation], real) != nullptr) return @(real);
    return resolved;
}

NSString* Executable(NSString* value) {
    NSString* candidate = value.stringByExpandingTildeInPath;
    if (!candidate.isAbsolutePath && ![candidate containsString:@"/"]) {
        NSString* pathVar = NSProcessInfo.processInfo.environment[@"PATH"] ?: @"";
        for (NSString* dir in [pathVar componentsSeparatedByString:@":"]) {
            if (dir.length == 0) continue;
            NSString* joined = [dir stringByAppendingPathComponent:candidate];
            if ([NSFileManager.defaultManager isExecutableFileAtPath:joined]) {
                candidate = joined;
                break;
            }
        }
    }
    candidate = ResolveStrict(candidate);
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:candidate isDirectory:&isDir];
    if (isDir && [candidate.pathExtension isEqualToString:@"app"]) {
        NSString* plistPath = [candidate stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSString* exe = info[@"CFBundleExecutable"];
        if (![exe isKindOfClass:NSString.class] || exe.length == 0) Fail("App has no CFBundleExecutable: " + Str(candidate));
        candidate = ResolveStrict([[candidate stringByAppendingPathComponent:@"Contents/MacOS"]
                                   stringByAppendingPathComponent:exe]);
    }
    if (![NSFileManager.defaultManager isExecutableFileAtPath:candidate]) {
        Fail("Not executable: " + Str(candidate));
    }
    return candidate;
}

NSString* Manifest(NSString* value, NSString* key) {
    NSString* path = ResolveStrict(value.stringByExpandingTildeInPath);
    NSData* data = [NSData dataWithContentsOfFile:path];
    if (data == nil) Fail("Could not read manifest: " + Str(path));
    id parsed = ParseJson(data);
    NSString* library = nil;
    if ([parsed isKindOfClass:NSDictionary.class]) {
        id section = ((NSDictionary*)parsed)[key];
        if ([section isKindOfClass:NSDictionary.class]) {
            id lib = ((NSDictionary*)section)[@"library_path"];
            if ([lib isKindOfClass:NSString.class]) library = lib;
        }
    }
    if (library.length == 0) Fail(Str(path) + " has no " + Str(key) + ".library_path");
    if (library.isAbsolutePath || [library containsString:@"/"]) {
        NSString* effective = library.isAbsolutePath
            ? library
            : [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:library];
        (void)ResolveStrict(effective);
    }
    return path;
}

NSString* ManifestLibrary(NSString* value, NSString* key) {
    NSString* path = Manifest(value, key);
    NSData* data = [NSData dataWithContentsOfFile:path];
    id parsed = data != nil ? ParseJson(data) : nil;
    NSString* library = nil;
    if ([parsed isKindOfClass:NSDictionary.class] &&
        [((NSDictionary*)parsed)[key] isKindOfClass:NSDictionary.class]) {
        id lib = ((NSDictionary*)((NSDictionary*)parsed)[key])[@"library_path"];
        if ([lib isKindOfClass:NSString.class]) library = lib;
    }
    if (library.length == 0) Fail(Str(path) + " has no " + Str(key) + ".library_path");
    NSString* effective = library.isAbsolutePath
        ? library
        : [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:library];
    return ResolveStrict(effective);
}

NSString* ProjectDir(NSString* value) {
    NSString* project = ResolveStrict(value.stringByExpandingTildeInPath);
    if (![NSFileManager.defaultManager fileExistsAtPath:[project stringByAppendingPathComponent:@"project.godot"]]) {
        Fail("Project directory must contain project.godot");
    }
    return project;
}

NSDictionary<NSString*, id>* AppEntry(id raw) {
    if (![raw isKindOfClass:NSDictionary.class]) {
        Fail("Each configured app must be an object with title and game or project");
    }
    NSDictionary* value = raw;
    NSString* rawTitle = [value[@"title"] isKindOfClass:NSString.class] ? value[@"title"] : @"";
    NSString* title = [[rawTitle stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (title.length == 0) Fail("Each configured app needs a title");
    BOOL hasGame = [value[@"game"] isKindOfClass:NSString.class] && ((NSString*)value[@"game"]).length > 0;
    BOOL hasProject = [value[@"project"] isKindOfClass:NSString.class] && ((NSString*)value[@"project"]).length > 0;
    if (hasGame == hasProject) {
        Fail("App '" + Str(title) + "' needs exactly one of game or project");
    }
    if (hasGame) return @{@"title": title, @"game": Executable(value[@"game"])};
    return @{@"title": title, @"project": ProjectDir(value[@"project"])};
}

void WriteConfigFile(NSString* state, NSDictionary* config) {
    NSString* temporary = [state stringByAppendingPathComponent:@"config.json.new"];
    NSString* destination = [state stringByAppendingPathComponent:@"config.json"];
    NSMutableData* data = [JsonData(config) mutableCopy];
    [data appendBytes:"\n" length:1];
    if (![data writeToFile:temporary atomically:NO]) Fail("Could not write " + Str(temporary));
    ::chmod([temporary fileSystemRepresentation], 0600);
    if (::rename([temporary fileSystemRepresentation], [destination fileSystemRepresentation]) != 0) {
        Fail(std::string("Could not install config: ") + std::strerror(errno));
    }
}


bool BootstrapConfig(NSString* state) {
    NSDictionary<NSString*, NSString*>* env = NSProcessInfo.processInfo.environment;
    NSString* dashboard = env[@"NEWT_BOOTSTRAP_DASHBOARD"];
    NSString* runtime = env[@"NEWT_BOOTSTRAP_RUNTIME"];
    if (dashboard.length == 0 || runtime.length == 0) return false;
    NSMutableDictionary* config = [@{@"dashboard": Executable(dashboard),
                                     @"runtime": Manifest(runtime, @"runtime")} mutableCopy];
    NSString* icd = env[@"NEWT_BOOTSTRAP_ICD"];
    if (icd.length > 0) config[@"icd"] = Manifest(icd, @"ICD");
    WriteConfigFile(state, config);
    return true;
}


NSDictionary<NSString*, id>* LoadConfig(NSString* state) {
    NSString* configPath = [state stringByAppendingPathComponent:@"config.json"];
    if (![NSFileManager.defaultManager fileExistsAtPath:configPath] && !BootstrapConfig(state)) {
        Fail("Newt is not configured. In Godot choose Project > Tools > Configure Newt, or run "
             "newt configure --runtime <runtime.json> [--dashboard <path>]. The runtime "
             "manifest is different from the OpenXR loader library.");
    }
    NSData* data = [NSData dataWithContentsOfFile:configPath];
    id parsed = data != nil ? ParseJson(data) : nil;
    if (![parsed isKindOfClass:NSDictionary.class]) Fail("Expected a config object in " + Str(configPath));
    NSMutableDictionary<NSString*, id>* config = [((NSDictionary*)parsed) mutableCopy];
    if (![config[@"runtime"] isKindOfClass:NSString.class]) Fail("Config needs a runtime manifest path");
    if ([config[@"dashboard"] isKindOfClass:NSString.class] && ((NSString*)config[@"dashboard"]).length > 0) {
        config[@"dashboard"] = Executable(config[@"dashboard"]);
    }
    config[@"runtime"] = Manifest(config[@"runtime"], @"runtime");
    if ([config[@"icd"] isKindOfClass:NSString.class] && ((NSString*)config[@"icd"]).length > 0) {
        config[@"icd"] = Manifest(config[@"icd"], @"ICD");
    }
    if ([config[@"launch_game"] isKindOfClass:NSString.class] && ((NSString*)config[@"launch_game"]).length > 0) {
        config[@"launch_game"] = Executable(config[@"launch_game"]);
    }
    if ([config[@"launch_project"] isKindOfClass:NSString.class] && ((NSString*)config[@"launch_project"]).length > 0) {
        config[@"launch_project"] = ProjectDir(config[@"launch_project"]);
    }
    if (config[@"apps"] != nil && config[@"apps"] != NSNull.null) {
        if (![config[@"apps"] isKindOfClass:NSArray.class]) Fail("Configured apps must be a list");
        NSMutableArray* apps = [NSMutableArray array];
        for (id app in (NSArray*)config[@"apps"]) [apps addObject:AppEntry(app)];
        config[@"apps"] = apps;
    }
    if (config[@"dashboard_env"] != nil && config[@"dashboard_env"] != NSNull.null) {
        id env = config[@"dashboard_env"];
        BOOL valid = [env isKindOfClass:NSDictionary.class];
        if (valid) {
            for (id k in (NSDictionary*)env) {
                if (![k isKindOfClass:NSString.class] || ![env[k] isKindOfClass:NSString.class]) valid = NO;
            }
        }
        if (!valid) Fail("dashboard_env must be an object of string keys and values");
    }
    return config;
}

// MARK: - Socket client

NSDictionary* ReceiveMessage(int fd) {
    NSMutableData* data = [NSMutableData data];
    std::vector<char> chunk(4096);
    while ([data rangeOfData:[NSData dataWithBytes:"\n" length:1]
                      options:0
                        range:NSMakeRange(0, data.length)].location == NSNotFound) {
        ssize_t n = ::recv(fd, chunk.data(), std::min(chunk.size(), kMaxMessage + 1 - data.length), 0);
        if (n <= 0) Fail("Incomplete request");
        [data appendBytes:chunk.data() length:static_cast<NSUInteger>(n)];
        if (data.length > kMaxMessage) Fail("Request too large");
    }
    NSUInteger newline = [data rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                   options:0 range:NSMakeRange(0, data.length)].location;
    id value = ParseJson([data subdataWithRange:NSMakeRange(0, newline)]);
    if (![value isKindOfClass:NSDictionary.class]) Fail("Expected an object");
    return value;
}

int ConnectSocket(NSString* endpoint) {
    int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) Fail(std::string("socket() failed: ") + std::strerror(errno));
    struct timeval timeout {12, 0};
    ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_un address {};
    address.sun_family = AF_UNIX;
    const char* path = [endpoint fileSystemRepresentation];
    if (std::strlen(path) >= sizeof(address.sun_path)) {
        ::close(fd);
        Fail("Socket path too long: " + Str(endpoint));
    }
    std::strncpy(address.sun_path, path, sizeof(address.sun_path) - 1);
    if (::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        int saved = errno;
        ::close(fd);
        errno = saved;
        struct SocketConnectError { int code; };
        throw SocketConnectError{saved};
    }
    return fd;
}

NSDictionary* Request(NSString* endpoint, NSDictionary* message) {
    int fd = ConnectSocket(endpoint);
    NSMutableData* payload = [JsonData(message) mutableCopy];
    [payload appendBytes:"\n" length:1];
    const uint8_t* bytes = static_cast<const uint8_t*>(payload.bytes);
    NSUInteger sent = 0;
    while (sent < payload.length) {
        ssize_t n = ::send(fd, bytes + sent, payload.length - sent, 0);
        if (n <= 0) {
            ::close(fd);
            Fail(std::string("send failed: ") + std::strerror(errno));
        }
        sent += static_cast<NSUInteger>(n);
    }
    NSDictionary* response = ReceiveMessage(fd);
    ::close(fd);
    return response;
}

bool TryStatus(NSString* endpoint, NSDictionary** out) {

    try {
        NSDictionary* response = Request(endpoint, @{@"action": @"status"});
        if (out != nullptr) *out = response;
        return true;
    } catch (...) {
        return false;
    }
}

// MARK: - Session manager

volatile std::sig_atomic_t gRunning = 1;
void HandleSignal(int) { gRunning = 0; }

bool WaitForExit(NSTask* task, NSTimeInterval seconds) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (task.isRunning && [deadline timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:0.05];
    }
    return !task.isRunning;
}

void StopChild(NSTask* child, NSFileHandle* stdinHandle, bool graceful) {
    if (child == nil) return;
    if (child.isRunning && graceful && stdinHandle != nil) {
        @try {
            [stdinHandle writeData:[@"stop\n" dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (...) {
        }
        WaitForExit(child, 3);
    }
    if (child.isRunning) {
        [child terminate];
        if (!WaitForExit(child, 2)) {
            ::kill(child.processIdentifier, SIGKILL);
            [child waitUntilExit];
        }
    }
    @try { [stdinHandle closeFile]; } @catch (...) {}
}

struct SessionManager {
    NSString* state = nil;
    NSString* endpoint = nil;
    NSString* appsFile = nil;
    NSDictionary<NSString*, id>* config = nil;
    NSMutableDictionary<NSString*, NSString*>* environment = nil;         // games
    NSMutableDictionary<NSString*, NSString*>* dashboardEnvironment = nil; // + host events
    NSTask* dashboard = nil;
    NSFileHandle* dashboardStdin = nil;
    NSTask* game = nil;
    NSString* errorText = nil;
    NSNumber* lastGameExit = nil;
    NSNumber* lastDashboardExit = nil;
    NSNumber* externalPid = nil;
    NSString* lease = nil;
    NSTimeInterval leaseDeadline = 0;
    NSFileHandle* log = nil;
    NSObject* logLock = [[NSObject alloc] init];
    std::deque<int> hostRequestQueue;
    std::deque<int> pendingHostRequests;
    NSMutableData* dashboardLineBuffer = [NSMutableData data];

    void ReloadConfig() {
        config = LoadConfig(state);
        environment = [NSProcessInfo.processInfo.environment mutableCopy];
        environment[@"XR_RUNTIME_JSON"] = (NSString*)config[@"runtime"];
        if ([config[@"icd"] isKindOfClass:NSString.class] && ((NSString*)config[@"icd"]).length > 0) {
            environment[@"VK_ICD_FILENAMES"] = (NSString*)config[@"icd"];
        } else {
            [environment removeObjectForKey:@"VK_ICD_FILENAMES"];
        }
        [environment removeObjectForKey:@"NEWT_HOST_EVENTS"];
        NSMutableString* titles = [NSMutableString string];
        if ([config[@"apps"] isKindOfClass:NSArray.class]) {
            for (NSDictionary* app in (NSArray*)config[@"apps"]) {
                [titles appendFormat:@"%@\n", (NSString*)app[@"title"]];
            }
        }
        [titles writeToFile:appsFile atomically:NO encoding:NSUTF8StringEncoding error:nil];
        // Host overrides win over the base environment, never over the two
        // protocol-critical variables set last.
        dashboardEnvironment = [environment mutableCopy];
        if ([config[@"dashboard_env"] isKindOfClass:NSDictionary.class]) {
            [dashboardEnvironment addEntriesFromDictionary:(NSDictionary*)config[@"dashboard_env"]];
        }
        dashboardEnvironment[@"NEWT_HOST_EVENTS"] = @"1";
        dashboardEnvironment[@"NEWT_APPS_FILE"] = appsFile;
    }

    void PumpDashboardData(NSData* data) {
        @synchronized(logLock) {
            [log writeData:data];
            [dashboardLineBuffer appendData:data];
            for (;;) {
                NSRange newline = [dashboardLineBuffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                                           options:0
                                                             range:NSMakeRange(0, dashboardLineBuffer.length)];
                if (newline.location == NSNotFound) break;
                NSData* lineData = [dashboardLineBuffer subdataWithRange:NSMakeRange(0, newline.location)];
                [dashboardLineBuffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:nullptr length:0];
                NSString* line = [[[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding]
                                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if ([line hasPrefix:@"NEWT_REQUEST:"]) {
                    NSString* suffix = [line substringFromIndex:@"NEWT_REQUEST:".length];
                    NSScanner* scanner = [NSScanner scannerWithString:suffix];
                    NSInteger value = 0;
                    if ([scanner scanInteger:&value] && scanner.isAtEnd) {
                        hostRequestQueue.push_back(static_cast<int>(value));
                    }
                }
            }
        }
    }

    NSTask* StartDashboard() {
        ReloadConfig();
        if (![config[@"dashboard"] isKindOfClass:NSString.class]) return nil;
        NSTask* child = [[NSTask alloc] init];
        child.executableURL = [NSURL fileURLWithPath:(NSString*)config[@"dashboard"]];
        child.environment = dashboardEnvironment;

        child.qualityOfService = NSQualityOfServiceUserInteractive;
        NSPipe* inPipe = [NSPipe pipe];
        NSPipe* outPipe = [NSPipe pipe];
        child.standardInput = inPipe;
        child.standardOutput = outPipe;
        child.standardError = log;
        dashboardStdin = inPipe.fileHandleForWriting;
        SessionManager* selfPtr = this;

        outPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle* handle) {
            NSData* data = handle.availableData;
            if (data.length > 0) {
                selfPtr->PumpDashboardData(data);
            } else {
                handle.readabilityHandler = nil;
            }
        };
        NSError* launchError = nil;
        if (![child launchAndReturnError:&launchError]) {
            Fail("Could not launch dashboard: " + Str(launchError.localizedDescription));
        }
        return child;
    }

    void StartGame(NSArray<NSString*>* argv, NSString* cwd) {
        StopChild(dashboard, dashboardStdin, true);
        dashboard = nil;
        dashboardStdin = nil;
        NSTask* child = [[NSTask alloc] init];
        child.executableURL = [NSURL fileURLWithPath:argv.firstObject];
        child.arguments = [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)];
        child.currentDirectoryURL = [NSURL fileURLWithPath:cwd];
        child.environment = environment;
        child.qualityOfService = NSQualityOfServiceUserInteractive;
        child.standardOutput = log;
        child.standardError = log;
        NSError* launchError = nil;
        if (![child launchAndReturnError:&launchError]) {
            dashboard = StartDashboard();
            Fail("Could not launch game: " + Str(launchError.localizedDescription));
        }
        game = child;
        errorText = nil;
    }

    void ConfiguredLaunch(NSNumber* index, NSArray<NSString*>** outArgv, NSString** outCwd) {
        NSDictionary* entry = nil;
        NSArray* apps = [config[@"apps"] isKindOfClass:NSArray.class] ? config[@"apps"] : @[];
        if (index != nil) {
            if (index.unsignedIntegerValue >= apps.count) {
                Fail("The dashboard asked for app #" + Str(index.stringValue) + ", but only " +
                     std::to_string(apps.count) + " app(s) are configured.");
            }
            entry = apps[index.unsignedIntegerValue];
        } else if (apps.count > 0) {
            entry = apps.firstObject;
        }
        NSArray<NSString*>* argv = nil;
        NSString* cwd = nil;
        NSString* godot = [config[@"godot"] isKindOfClass:NSString.class] ? config[@"godot"] : @"godot";
        if (entry != nil && [entry[@"game"] isKindOfClass:NSString.class]) {
            argv = @[(NSString*)entry[@"game"]];
            cwd = argv.firstObject.stringByDeletingLastPathComponent;
        } else if (entry != nil) {
            argv = @[Executable(godot), @"--path", (NSString*)entry[@"project"]];
            cwd = entry[@"project"];
        } else if ([config[@"launch_game"] isKindOfClass:NSString.class]) {
            argv = @[(NSString*)config[@"launch_game"]];
            cwd = argv.firstObject.stringByDeletingLastPathComponent;
        } else if ([config[@"launch_project"] isKindOfClass:NSString.class]) {
            argv = @[Executable(godot), @"--path", (NSString*)config[@"launch_project"]];
            cwd = config[@"launch_project"];
        } else {
            Fail("The dashboard asked to launch an app, but no launch target is configured. "
                 "Run newt configure with --app, --launch-game, or --launch-project.");
        }
        *outArgv = [argv arrayByAddingObjectsFromArray:@[@"--xr-mode", @"on", @"--rendering-method", @"mobile",
                                                         @"--rendering-driver", @"vulkan"]];
        *outCwd = cwd;
    }

    bool PidAlive(pid_t pid) {
        return ::kill(pid, 0) == 0;
    }


    void Tick() {
        if (externalPid != nil && !PidAlive(externalPid.intValue)) {
            externalPid = nil;
            lease = nil;
            try { dashboard = StartDashboard(); } catch (const NewtError& e) { errorText = NStr(e.message); }
        }
        if (lease != nil && externalPid == nil && CFAbsoluteTimeGetCurrent() > leaseDeadline) {
            lease = nil;
            errorText = @"Game startup timed out; dashboard restored";
            try { dashboard = StartDashboard(); } catch (const NewtError& e) { errorText = NStr(e.message); }
        }
        if (game != nil && !game.isRunning) {
            lastGameExit = @(game.terminationStatus);
            game = nil;
            try { dashboard = StartDashboard(); } catch (const NewtError& e) { errorText = NStr(e.message); }
        }
        if (dashboard != nil && !dashboard.isRunning) {

            lastDashboardExit = @(dashboard.terminationStatus);
            errorText = dashboard.terminationStatus == 2
                ? @"Dashboard refused the simulated runtime fallback: the headset is busy, "
                   "disconnected, or held by another app (see children.log)"
                : [NSString stringWithFormat:@"Dashboard exited with status %d", dashboard.terminationStatus];
            StopChild(dashboard, dashboardStdin, false);
            dashboard = nil;
            dashboardStdin = nil;
        }
        std::deque<int> drained;
        @synchronized(logLock) { drained.swap(hostRequestQueue); }
        bool nothingConfigured = !([config[@"apps"] isKindOfClass:NSArray.class] && ((NSArray*)config[@"apps"]).count > 0) &&
                                 ![config[@"launch_game"] isKindOfClass:NSString.class] &&
                                 ![config[@"launch_project"] isKindOfClass:NSString.class];
        for (int requestCode : drained) {
            bool isLaunch = requestCode == 3 || requestCode >= 100;
            if (isLaunch && game == nil && lease == nil && !nothingConfigured) {
                try {
                    NSArray<NSString*>* argv = nil;
                    NSString* cwd = nil;
                    ConfiguredLaunch(requestCode == 3 ? nil : @(requestCode - 100), &argv, &cwd);
                    StartGame(argv, cwd);
                } catch (const NewtError& e) {
                    errorText = NStr(e.message);
                }
            } else {
                pendingHostRequests.push_back(requestCode);
                while (pendingHostRequests.size() > 32) pendingHostRequests.pop_front();
            }
        }
    }

    NSString* StateName() {
        if (game != nil || externalPid != nil) return @"game";
        if (lease != nil) return @"preparing";
        if (dashboard != nil) return @"dashboard";
        return @"idle";
    }

    NSDictionary* HandleMessage(NSDictionary* message) {
        NSString* action = [message[@"action"] isKindOfClass:NSString.class] ? message[@"action"] : nil;
        NSMutableArray<NSNumber*>* drainedRequests = nil;
        NSNumber* delivered = nil;
        NSString* issuedToken = nil;
        if ([action isEqualToString:@"prepare"]) {
            if (game != nil || lease != nil) Fail("The headset is already reserved by a game");
            StopChild(dashboard, dashboardStdin, true);
            dashboard = nil;
            dashboardStdin = nil;
            uint8_t bytes[24];
            arc4random_buf(bytes, sizeof(bytes));
            NSMutableString* token = [NSMutableString string];
            for (uint8_t b : bytes) [token appendFormat:@"%02x", b];
            lease = token;
            issuedToken = token;
            double timeout = 60;
            if ([config[@"startup_timeout"] isKindOfClass:NSNumber.class]) timeout = ((NSNumber*)config[@"startup_timeout"]).doubleValue;
            leaseDeadline = CFAbsoluteTimeGetCurrent() + std::max(1.0, std::min(120.0, timeout));
            errorText = nil;
        } else if ([action isEqualToString:@"attach"]) {
            NSString* token = [message[@"token"] isKindOfClass:NSString.class] ? message[@"token"] : @"";
            if (lease == nil || ![token isEqualToString:lease]) Fail("Invalid or expired launch token");
            id pidValue = message[@"pid"];
            if (![pidValue isKindOfClass:NSNumber.class] || ((NSNumber*)pidValue).intValue <= 1 ||
                ((NSNumber*)pidValue).intValue == ::getpid()) Fail("Invalid game process");
            pid_t pid = ((NSNumber*)pidValue).intValue;
            if (externalPid != nil && externalPid.intValue != pid) Fail("Launch token is already attached to another game");
            if (!PidAlive(pid)) Fail("Invalid game process");
            externalPid = @(pid);
        } else if ([action isEqualToString:@"launch"]) {
            if (game != nil || lease != nil) Fail("A game is already running. Close it before launching another.");
            id rawArgv = message[@"argv"];
            if (![rawArgv isKindOfClass:NSArray.class] || ((NSArray*)rawArgv).count == 0) {
                Fail("Expected an executable and string arguments");
            }
            NSMutableArray<NSString*>* argv = [NSMutableArray array];
            for (id item in (NSArray*)rawArgv) {
                if (![item isKindOfClass:NSString.class] || [(NSString*)item containsString:@"\0"]) {
                    Fail("Expected an executable and string arguments");
                }
                [argv addObject:item];
            }
            argv[0] = Executable(argv[0]);
            NSString* cwd = [message[@"cwd"] isKindOfClass:NSString.class] && ((NSString*)message[@"cwd"]).length > 0
                ? ResolveStrict(message[@"cwd"]) : argv[0].stringByDeletingLastPathComponent;
            BOOL isDir = NO;
            [NSFileManager.defaultManager fileExistsAtPath:cwd isDirectory:&isDir];
            if (!isDir) Fail("Working directory must be a directory");
            // Validated before interrupting the dashboard; StartGame reaps it.
            StartGame(argv, cwd);
        } else if ([action isEqualToString:@"resume"]) {
            if (game != nil || lease != nil) Fail("Close the game before resuming the dashboard");
            if (dashboard == nil) dashboard = StartDashboard();
            errorText = nil;
        } else if ([action isEqualToString:@"stop-game"]) {
            if (game != nil) {
                StopChild(game, nil, false);
                lastGameExit = @(game.terminationStatus);
                game = nil;
                dashboard = StartDashboard();
            } else if (externalPid != nil) {
                ::kill(externalPid.intValue, SIGTERM);
            }
        } else if ([action isEqualToString:@"stop"]) {
            gRunning = 0;
        } else if ([action isEqualToString:@"poll-host-requests"]) {
            drainedRequests = [NSMutableArray array];
            for (int code : pendingHostRequests) [drainedRequests addObject:@(code)];
            pendingHostRequests.clear();
        } else if ([action isEqualToString:@"command"]) {
            id textValue = message[@"command"];
            if (![textValue isKindOfClass:NSString.class] || [(NSString*)textValue containsString:@"\n"] ||
                [(NSString*)textValue containsString:@"\0"]) {
                Fail("Expected a single-line command string");
            }
            delivered = @NO;
            if (dashboard != nil && dashboard.isRunning && dashboardStdin != nil) {
                @try {
                    [dashboardStdin writeData:[[(NSString*)textValue stringByAppendingString:@"\n"]
                                                dataUsingEncoding:NSUTF8StringEncoding]];
                    delivered = @YES;
                } @catch (...) {
                    delivered = @NO;
                }
            }
        } else if (![action isEqualToString:@"status"]) {
            Fail("Unknown request");
        }
        NSMutableArray<NSString*>* appTitles = [NSMutableArray array];
        if ([config[@"apps"] isKindOfClass:NSArray.class]) {
            for (NSDictionary* app in (NSArray*)config[@"apps"]) [appTitles addObject:app[@"title"]];
        }
        NSMutableDictionary* response = [@{
            @"ok": @YES,
            @"state": StateName(),
            @"game_pid": game != nil ? @(game.processIdentifier) : (externalPid ?: NSNull.null),
            @"last_game_exit": lastGameExit ?: NSNull.null,
            @"last_dashboard_exit": lastDashboardExit ?: NSNull.null,
            @"error": errorText ?: NSNull.null,
            @"apps": appTitles,
            @"protocol": @1,
            @"manager": @"newtd",
        } mutableCopy];
        if (issuedToken != nil) {
            response[@"token"] = issuedToken;
            response[@"environment"] = @{
                @"XR_RUNTIME_JSON": (NSString*)config[@"runtime"],
                @"VK_ICD_FILENAMES": [config[@"icd"] isKindOfClass:NSString.class] ? (NSString*)config[@"icd"] : @"",
            };
        }
        if (drainedRequests != nil) response[@"requests"] = drainedRequests;
        if (delivered != nil) response[@"delivered"] = delivered;
        return response;
    }
};

int Serve(NSString* state, NSString* endpoint) {
    // Lock file prevents a second manager from unlinking an active socket.
    NSString* lockPath = [endpoint.stringByDeletingLastPathComponent
                          stringByAppendingPathComponent:@"session.lock"];
    int lockFd = ::open([lockPath fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
    if (lockFd < 0) Fail(std::string("Could not open session lock: ") + std::strerror(errno));
    if (::flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
        ::close(lockFd);
        return 0; // Another manager already owns the socket.
    }
    SessionManager manager;
    manager.state = state;
    manager.endpoint = endpoint;
    manager.appsFile = [state stringByAppendingPathComponent:@"apps.txt"];
    manager.ReloadConfig(); // Fail fast (e.g. unconfigured) before binding.
    NSString* logPath = [state stringByAppendingPathComponent:@"children.log"];
    if (![NSFileManager.defaultManager fileExistsAtPath:logPath]) {
        [NSFileManager.defaultManager createFileAtPath:logPath contents:nil attributes:nil];
    }
    manager.log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [manager.log seekToEndOfFile];
    if (manager.log == nil) Fail("Could not open children.log in " + Str(state));

    ::signal(SIGTERM, HandleSignal);
    ::signal(SIGINT, HandleSignal);
    // Under launchd (see daemon/launchd/), the listening socket is created
    // by launchd and handed to us on first connect; launchd keeps owning the
    // socket file across daemon restarts, so we must neither bind nor unlink
    // it. Outside launchd, launch_activate_socket fails and we bind our own
    // socket ourselves.
    int serverFd = -1;
    bool launchdOwned = false;
    {
        int* fds = nullptr;
        size_t count = 0;
        if (::launch_activate_socket("SessionSocket", &fds, &count) == 0 && count >= 1) {
            serverFd = fds[0];
            for (size_t i = 1; i < count; i++) ::close(fds[i]);
            std::free(fds);
            launchdOwned = true;
        }
    }
    const char* path = [endpoint fileSystemRepresentation];
    if (!launchdOwned) {
        ::unlink(path);
        serverFd = ::socket(AF_UNIX, SOCK_STREAM, 0);
        if (serverFd < 0) Fail(std::string("socket() failed: ") + std::strerror(errno));
        struct sockaddr_un address {};
        address.sun_family = AF_UNIX;
        if (std::strlen(path) >= sizeof(address.sun_path)) Fail("Socket path too long: " + Str(endpoint));
        std::strncpy(address.sun_path, path, sizeof(address.sun_path) - 1);
        if (::bind(serverFd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
            Fail(std::string("bind failed: ") + std::strerror(errno));
        }
        ::chmod(path, 0600);
        ::listen(serverFd, 4);
    }
    try {
        manager.dashboard = manager.StartDashboard();
    } catch (const NewtError& e) {
        manager.errorText = NStr(e.message);
    }
    while (gRunning) {
        @autoreleasepool {
            try { manager.Tick(); } catch (const NewtError& e) { manager.errorText = NStr(e.message); }
            struct pollfd pfd {serverFd, POLLIN, 0};
            int ready = ::poll(&pfd, 1, 200);
            if (ready <= 0 || (pfd.revents & POLLIN) == 0) continue;
            int client = ::accept(serverFd, nullptr, nullptr);
            if (client < 0) continue;
            struct timeval timeout {2, 0};
            ::setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            ::setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            NSDictionary* response = nil;
            try {
                response = manager.HandleMessage(ReceiveMessage(client));
            } catch (const NewtError& e) {
                response = @{@"ok": @NO, @"error": NStr(e.message)};
            } catch (...) {
                response = @{@"ok": @NO, @"error": @"Internal manager error"};
            }
            @try {
                NSMutableData* payload = [JsonData(response) mutableCopy];
                [payload appendBytes:"\n" length:1];
                const uint8_t* bytes = static_cast<const uint8_t*>(payload.bytes);
                NSUInteger sent = 0;
                while (sent < payload.length) {
                    ssize_t n = ::send(client, bytes + sent, payload.length - sent, 0);
                    if (n <= 0) break;
                    sent += static_cast<NSUInteger>(n);
                }
            } @catch (...) {}
            ::close(client);
        }
    }
    StopChild(manager.game, nil, false);
    StopChild(manager.dashboard, manager.dashboardStdin, true);
    ::close(serverFd);
    if (!launchdOwned) ::unlink(path);
    [manager.log closeFile];
    ::close(lockFd);
    return 0;
}

NSDictionary* EnsureSession(NSString* state, NSString* endpoint) {
    NSDictionary* status = nil;
    if (TryStatus(endpoint, &status)) return status;
    (void)LoadConfig(state); // Report missing setup before detaching.
    NSString* logPath = [state stringByAppendingPathComponent:@"manager.log"];
    int logFd = ::open([logPath fileSystemRepresentation], O_CREAT | O_WRONLY | O_APPEND, 0644);
    int devNull = ::open("/dev/null", O_RDONLY);
    char selfPath[PATH_MAX];
    uint32_t size = sizeof(selfPath);
    if (_NSGetExecutablePath(selfPath, &size) != 0) Fail("Could not locate newtd executable");
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, devNull, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, logFd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, logFd, STDERR_FILENO);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    char* const argv[] = {selfPath, const_cast<char*>("serve"), nullptr};
    pid_t pid = 0;
    int spawnResult = ::posix_spawn(&pid, selfPath, &actions, &attr, argv, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    ::close(logFd);
    ::close(devNull);
    if (spawnResult != 0) Fail("Could not start newtd: " + std::string(std::strerror(spawnResult)));
    for (int i = 0; i < 100; i++) {
        [NSThread sleepForTimeInterval:0.05];
        if (TryStatus(endpoint, &status)) return status;
    }
    Fail("Newt failed to start; see " + Str(logPath));
}

void PrintResult(id result) {
    NSError* error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:result
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&error];
    NSString* text = data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    std::fprintf(stdout, "%s\n", [text UTF8String]);
}

bool ResultOk(NSDictionary* result) {
    return [result[@"ok"] isKindOfClass:NSNumber.class] && ((NSNumber*)result[@"ok"]).boolValue;
}

NSString* FlagValue(const std::vector<std::string>& args, const char* flag) {
    for (size_t i = 0; i + 1 < args.size(); i++) {
        if (args[i] == flag) return NStr(args[i + 1]);
    }
    return nil;
}

std::vector<std::string> FlagValues(const std::vector<std::string>& args, const char* flag) {
    std::vector<std::string> values;
    for (size_t i = 0; i + 1 < args.size(); i++) {
        if (args[i] == flag) values.push_back(args[i + 1]);
    }
    return values;
}

NSDictionary* AppSpec(NSString* spec) {
    NSRange eq = [spec rangeOfString:@"="];
    NSString* title = @"";
    NSString* path = spec;
    if (eq.location != NSNotFound) {
        NSString* maybeTitle = [spec substringToIndex:eq.location];
        NSString* maybePath = [spec substringFromIndex:eq.location + 1];
        if (maybePath.length > 0 && ![maybeTitle containsString:@"/"]) {
            title = maybeTitle;
            path = maybePath;
        }
    }
    NSString* expanded = path.stringByExpandingTildeInPath;
    if ([NSFileManager.defaultManager fileExistsAtPath:[expanded stringByAppendingPathComponent:@"project.godot"]]) {
        return @{@"title": title.length > 0 ? title : expanded.stringByResolvingSymlinksInPath.lastPathComponent,
                 @"project": expanded};
    }
    return @{@"title": title.length > 0 ? title : expanded.lastPathComponent.stringByDeletingPathExtension,
             @"game": path};
}

NSString* SelfExecutablePath() {
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) Fail("Could not locate newtd executable");
    char real[PATH_MAX];
    return ::realpath(path, real) != nullptr ? @(real) : @(path);
}

void RunChecked(NSArray<NSString*>* argv, NSString* stdinText) {
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:argv.firstObject];
    task.arguments = [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)];
    NSPipe* input = nil;
    if (stdinText != nil) {
        input = [NSPipe pipe];
        task.standardInput = input;
    }
    NSError* error = nil;
    if (![task launchAndReturnError:&error]) {
        Fail("Could not run " + Str(argv.firstObject) + ": " + Str(error.localizedDescription));
    }
    if (input != nil) {
        @try {
            [input.fileHandleForWriting writeData:[stdinText dataUsingEncoding:NSUTF8StringEncoding]];
            [input.fileHandleForWriting closeFile];
        } @catch (...) {}
    }
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        Fail(Str(argv.firstObject) + " exited with status " + std::to_string(task.terminationStatus));
    }
}

NSString* RunOutput(NSArray<NSString*>* argv) {
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:argv.firstObject];
    task.arguments = [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)];
    NSPipe* output = [NSPipe pipe];
    task.standardOutput = output;
    NSError* error = nil;
    if (![task launchAndReturnError:&error]) {
        Fail("Could not run " + Str(argv.firstObject) + ": " + Str(error.localizedDescription));
    }
    NSData* data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        Fail(Str(argv.firstObject) + " exited with status " + std::to_string(task.terminationStatus));
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

// Destination name a bundled dylib gets: its LC_ID_DYLIB basename (what
// dependents reference), falling back to the file name. Same rule as
// tools/bundle-dylib-closure.py's install_basename().
NSString* InstallBasename(NSString* path) {
    @try {
        NSString* output = RunOutput(@[@"/usr/bin/otool", @"-D", path]);
        NSArray<NSString*>* lines = [output componentsSeparatedByString:@"\n"];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSString* value = [lines[i] stringByTrimmingCharactersInSet:
                               NSCharacterSet.whitespaceCharacterSet];
            if ([value hasSuffix:@".dylib"]) return value.lastPathComponent;
        }
    } @catch (...) {}
    return path.lastPathComponent;
}

void ValidateBundleId(NSString* bundleId) {
    NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"];
    bool valid = bundleId.length > 0 && bundleId.length <= 255 &&
                 [[NSCharacterSet alphanumericCharacterSet] characterIsMember:[bundleId characterAtIndex:0]] &&
                 [[NSCharacterSet alphanumericCharacterSet] characterIsMember:[bundleId characterAtIndex:bundleId.length - 1]] &&
                 [bundleId rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
    if (!valid) Fail("Invalid --bundle-id: " + Str(bundleId));
}

// First 12 hex chars of SHA-256(bundle-id): IPC dir scope that stays far
// under AF_UNIX's sun_path limit for any bundle-id length.
NSString* IpcHash(NSString* bundleId) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    NSData* data = [bundleId dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256(data.bytes, static_cast<CC_LONG>(data.length), digest);
    NSMutableString* hash = [NSMutableString string];
    for (int i = 0; i < 6; i++) [hash appendFormat:@"%02x", digest[i]];
    return hash;
}

void RewriteManifest(NSString* source, NSString* key, NSString* destination) {
    NSData* data = [NSData dataWithContentsOfFile:Manifest(source, key)];
    id parsed = data != nil ? ParseJson(data) : nil;
    if (![parsed isKindOfClass:NSDictionary.class]) Fail("Expected a manifest object in " + Str(source));
    NSMutableDictionary* document = [((NSDictionary*)parsed) mutableCopy];
    NSMutableDictionary* section = [document[key] isKindOfClass:NSDictionary.class]
        ? [((NSDictionary*)document[key]) mutableCopy] : [NSMutableDictionary dictionary];
    section[@"library_path"] = [@"lib/" stringByAppendingString:InstallBasename(ManifestLibrary(source, key))];
    document[key] = section;
    NSMutableData* out = [JsonData(document) mutableCopy];
    [out appendBytes:"\n" length:1];
    if (![out writeToFile:destination atomically:NO]) Fail("Could not write " + Str(destination));
}

// Bundling runs only on the developer's Mac at export time, so shelling out
// to the Python closure tool here is fine (not an installed-manager path).
NSString* BundleDylibClosureTool() {
    NSString* override = NSProcessInfo.processInfo.environment[@"NEWT_DYLIB_CLOSURE_TOOL"];
    NSString* dir = SelfExecutablePath().stringByDeletingLastPathComponent;
    NSArray<NSString*>* candidates = @[
        override ?: @"",
        [dir stringByAppendingPathComponent:@"bundle-dylib-closure.py"],
        [[dir stringByAppendingPathComponent:@"../share/Newt/tools"]
         stringByAppendingPathComponent:@"bundle-dylib-closure.py"],
        [[dir stringByAppendingPathComponent:@"../tools"]
         stringByAppendingPathComponent:@"bundle-dylib-closure.py"],
        [[dir stringByAppendingPathComponent:@"../../tools"]
         stringByAppendingPathComponent:@"bundle-dylib-closure.py"],
    ];
    for (NSString* candidate in candidates) {
        if (candidate.length > 0 &&
            [NSFileManager.defaultManager fileExistsAtPath:candidate]) {
            return candidate.stringByStandardizingPath;
        }
    }
    Fail("Could not locate bundle-dylib-closure.py (set NEWT_DYLIB_CLOSURE_TOOL)");
}

// Standalone bundles have no menu to return to. The stub plays a silent
// dashboard until the manager stops it for the game; on the manager's
// post-game dashboard restart (same manager pid = $PPID, marker present)
// it stops the manager instead.
constexpr const char* kDashboardStub =
    "#!/bin/sh\n"
    "here=$(dirname \"$0\")\n"
    "marker=\"${NEWT_IPC_DIR:-/tmp}/newt-standalone-dashboard-${PPID:-$$}\"\n"
    "if [ -e \"$marker\" ]; then\n"
    "    rm -f \"$marker\"\n"
    "    \"$here/newtd\" stop >/dev/null 2>&1 || true\n"
    "    exit 0\n"
    "fi\n"
    ": > \"$marker\" 2>/dev/null || true\n"
    "while IFS= read -r line; do\n"
    "    [ \"$line\" = \"stop\" ] && break\n"
    "done\n"
    "exit 0\n";

// Development bundle: keep the original export intact inside a new .app
// whose native launcher submits it to the session manager (`newtd run`).
// The generated bootstrap execs the bundled newtd binary. With --runtime and
// --bundle-id (and optional --icd) it instead produces a self-contained
// standalone bundle: see docs/GODOT-STANDALONE-EXPORT.md.
int RunBundle(const std::vector<std::string>& args) {
    NSString* gameValue = FlagValue(args, "--game");
    NSString* outputValue = FlagValue(args, "--output");
    if (gameValue == nil || outputValue == nil) Fail("bundle requires --game and --output");
    NSString* runtimeValue = FlagValue(args, "--runtime");
    NSString* icdValue = FlagValue(args, "--icd");
    NSString* bundleId = FlagValue(args, "--bundle-id");
    bool standalone = runtimeValue != nil;
    if (icdValue != nil && !standalone) Fail("--icd requires --runtime (standalone bundle)");
    if (standalone && bundleId == nil) Fail("Standalone bundle (--runtime) requires --bundle-id");
    if (bundleId != nil && !standalone) Fail("--bundle-id requires --runtime (standalone bundle)");
    if (bundleId != nil) ValidateBundleId(bundleId);
    NSString* source = ResolveStrict(gameValue.stringByExpandingTildeInPath);
    NSString* destination = outputValue.stringByExpandingTildeInPath;
    if (![source.pathExtension isEqualToString:@"app"] || ![destination.pathExtension isEqualToString:@"app"]) {
        Fail("Source and output must be .app bundles");
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:destination] ||
        [destination hasPrefix:[source stringByAppendingString:@"/"]]) {
        Fail("Output must be a new path outside the original app");
    }
    (void)Executable(source); // Verify the export before copying it.
    // Validate standalone inputs before copying anything.
    NSMutableArray<NSString*>* dylibs = [NSMutableArray array];
    if (standalone) {
        [dylibs addObject:ManifestLibrary(runtimeValue, @"runtime")];
        if (icdValue != nil) [dylibs addObject:ManifestLibrary(icdValue, @"ICD")];
    }
    NSString* resources = [destination stringByAppendingPathComponent:@"Contents/Resources"];
    NSString* macosDir = [destination stringByAppendingPathComponent:@"Contents/MacOS"];
    NSError* error = nil;
    NSFileManager* fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:resources withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![fm createDirectoryAtPath:macosDir withIntermediateDirectories:YES attributes:nil error:&error]) {
        Fail("Could not create bundle directories: " + Str(error.localizedDescription));
    }
    if (![fm copyItemAtPath:source toPath:[resources stringByAppendingPathComponent:@"Game.app"] error:&error]) {
        Fail("Could not copy game app: " + Str(error.localizedDescription));
    }
    const char* identityEnv = std::getenv("CODESIGN_IDENTITY");
    NSString* identity = identityEnv != nullptr && identityEnv[0] != '\0' ? @(identityEnv) : @"-";
    NSString* stem = source.lastPathComponent.stringByDeletingPathExtension;
    NSString* identifier = nil;
    NSString* scope = nil;
    NSString* launcherSource = nil;
    if (standalone) {
        NSString* newtDir = [resources stringByAppendingPathComponent:@"Newt"];
        NSString* libDir = [newtDir stringByAppendingPathComponent:@"lib"];
        if (![fm createDirectoryAtPath:libDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            Fail("Could not create Newt lib directory: " + Str(error.localizedDescription));
        }
        if (![fm copyItemAtPath:SelfExecutablePath()
                          toPath:[newtDir stringByAppendingPathComponent:@"newtd"] error:&error]) {
            Fail("Could not copy newtd: " + Str(error.localizedDescription));
        }
        NSMutableArray<NSString*>* closureArgv = [@[Executable(@"python3"), BundleDylibClosureTool(), libDir] mutableCopy];
        [closureArgv addObjectsFromArray:dylibs];
        (void)RunOutput(closureArgv); // Capture stdout so bundle's JSON result stays clean.
        RewriteManifest(runtimeValue, @"runtime", [newtDir stringByAppendingPathComponent:@"runtime.json"]);
        if (icdValue != nil) {
            RewriteManifest(icdValue, @"ICD", [newtDir stringByAppendingPathComponent:@"icd.json"]);
        }
        NSString* stubPath = [newtDir stringByAppendingPathComponent:@"dashboard-stub.sh"];
        if (![@(kDashboardStub) writeToFile:stubPath atomically:NO
                                   encoding:NSUTF8StringEncoding error:&error]) {
            Fail("Could not write dashboard stub: " + Str(error.localizedDescription));
        }
        ::chmod([stubPath fileSystemRepresentation], 0755);
        NSMutableString* code = [NSMutableString stringWithString:
            @"#import <Foundation/Foundation.h>\n"
            "#include <unistd.h>\n#include <stdio.h>\n#include <stdlib.h>\n"
            "int main(void) { @autoreleasepool {\n"
            "    NSString *r=[[NSBundle mainBundle] resourcePath];\n"
            "    NSString *n=[r stringByAppendingPathComponent:@\"Newt\"];\n"];
        [code appendFormat:
            @"    NSString *state=[[[NSHomeDirectory() stringByAppendingPathComponent:@\"Library/Application Support\"] stringByAppendingPathComponent:@\"%@\"] stringByAppendingPathComponent:@\"Newt\"];\n"
            "    NSString *ipc=[NSString stringWithFormat:@\"/tmp/newt-session-%@-%%d\",getuid()];\n",
            bundleId, IpcHash(bundleId)];
        [code appendString:
            @"    setenv(\"NEWT_STATE_DIR\",[state fileSystemRepresentation],1);\n"
            "    setenv(\"NEWT_IPC_DIR\",[ipc fileSystemRepresentation],1);\n"
            "    setenv(\"NEWT_BOOTSTRAP_DASHBOARD\",[[n stringByAppendingPathComponent:@\"dashboard-stub.sh\"] fileSystemRepresentation],1);\n"
            "    setenv(\"NEWT_BOOTSTRAP_RUNTIME\",[[n stringByAppendingPathComponent:@\"runtime.json\"] fileSystemRepresentation],1);\n"];
        if (icdValue != nil) {
            [code appendString:@"    setenv(\"NEWT_BOOTSTRAP_ICD\",[[n stringByAppendingPathComponent:@\"icd.json\"] fileSystemRepresentation],1);\n"];
        }
        [code appendString:
            @"    const char *newtd=[[n stringByAppendingPathComponent:@\"newtd\"] fileSystemRepresentation];\n"
            "    const char *game=[[r stringByAppendingPathComponent:@\"Game.app\"] fileSystemRepresentation];\n"
            "    execl(newtd,newtd,\"run\",\"--game\",game,(char*)NULL);\n"
            "    perror(\"Newt launcher\"); return 1;\n"
            "} }\n"];
        launcherSource = code;
        identifier = bundleId;
        scope = @"self-contained; requires no installed Newt";
    } else {
        if (![fm copyItemAtPath:SelfExecutablePath()
                          toPath:[resources stringByAppendingPathComponent:@"newtd"] error:&error]) {
            Fail("Could not copy newtd: " + Str(error.localizedDescription));
        }
        launcherSource = @"#import <Foundation/Foundation.h>\n"
            "#include <unistd.h>\n#include <stdio.h>\n"
            "int main(void) { @autoreleasepool {\n"
            "    NSString *r=[[NSBundle mainBundle] resourcePath];\n"
            "    const char *newtd=[[r stringByAppendingPathComponent:@\"newtd\"] fileSystemRepresentation];\n"
            "    const char *game=[[r stringByAppendingPathComponent:@\"Game.app\"] fileSystemRepresentation];\n"
            "    execl(newtd,newtd,\"run\",\"--game\",game,(char*)NULL);\n"
            "    perror(\"Newt launcher\"); return 1;\n"
            "} }\n";
        NSMutableString* devIdentifier = [NSMutableString stringWithString:@"org.newt.development."];
        for (NSUInteger i = 0; i < stem.length; i++) {
            unichar c = [stem characterAtIndex:i];
            [devIdentifier appendFormat:@"%c", ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c]
                                             ? static_cast<char>(c) : '-')];
        }
        identifier = devIdentifier;
        scope = @"development Mac; requires configured Newt";
    }
    RunChecked(@[@"/usr/bin/clang", @"-x", @"objective-c", @"-fobjc-arc", @"-framework", @"Foundation",
                 @"-o", [macosDir stringByAppendingPathComponent:@"NewtLaunch"], @"-"],
               launcherSource);
    NSDictionary* info = @{
        @"CFBundleExecutable": @"NewtLaunch",
        @"CFBundleName": stem,
        @"CFBundleIdentifier": identifier,
        @"CFBundlePackageType": @"APPL",
        @"CFBundleVersion": @"1",
        @"LSMinimumSystemVersion": @"12.0",
    };
    NSString* plistPath = [destination stringByAppendingPathComponent:@"Contents/Info.plist"];
    if (![info writeToFile:plistPath atomically:NO]) Fail("Could not write Info.plist");
    RunChecked(@[@"/usr/bin/codesign", @"--force", @"--sign", identity, destination], nil);
    NSMutableDictionary* result = [@{@"ok": @YES, @"bundle": destination, @"scope": scope} mutableCopy];
    if (standalone) result[@"bundle_id"] = bundleId;
    PrintResult(result);
    return 0;
}

int RunConfigure(NSString* state, const std::vector<std::string>& args) {
    NSString* dashboard = FlagValue(args, "--dashboard");
    NSString* runtime = FlagValue(args, "--runtime");
    if (runtime == nil) Fail("configure requires --runtime");
    NSMutableDictionary* config = [@{@"runtime": Manifest(runtime, @"runtime")} mutableCopy];
    // --dashboard is optional: with none configured, Tick()/StartDashboard()
    // simply never start one, and a game reaches Monado entirely through the
    // `launch`/`prepare`+`attach` socket actions instead.
    if (dashboard != nil) config[@"dashboard"] = Executable(dashboard);
    if (NSString* icd = FlagValue(args, "--icd")) config[@"icd"] = Manifest(icd, @"ICD");
    if (NSString* godot = FlagValue(args, "--godot")) config[@"godot"] = Executable(godot);
    NSString* launchGame = FlagValue(args, "--launch-game");
    NSString* launchProject = FlagValue(args, "--launch-project");
    if (launchGame != nil && launchProject != nil) Fail("Choose either --launch-game or --launch-project, not both");
    if (launchGame != nil) config[@"launch_game"] = Executable(launchGame);
    if (launchProject != nil) config[@"launch_project"] = ProjectDir(launchProject);
    std::vector<std::string> apps = FlagValues(args, "--app");
    if (!apps.empty()) {
        NSMutableArray* entries = [NSMutableArray array];
        for (const std::string& spec : apps) [entries addObject:AppEntry(AppSpec(NStr(spec)))];
        config[@"apps"] = entries;
    }
    std::vector<std::string> envs = FlagValues(args, "--env");
    if (!envs.empty()) {
        NSMutableDictionary* pairs = [NSMutableDictionary dictionary];
        for (const std::string& spec : envs) {
            NSRange eq = [NStr(spec) rangeOfString:@"="];
            if (eq.location == NSNotFound || eq.location == 0) Fail("--env expects KEY=VALUE");
            pairs[[NStr(spec) substringToIndex:eq.location]] = [NStr(spec) substringFromIndex:eq.location + 1];
        }
        config[@"dashboard_env"] = pairs;
    }
    NSString* destination = [state stringByAppendingPathComponent:@"config.json"];
    WriteConfigFile(state, config);
    PrintResult(@{@"ok": @YES, @"config": destination,
                  @"note": @"Restart Newt to apply configuration changes"});
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    ::signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        try {
            std::vector<std::string> args;
            for (int i = 1; i < argc; i++) args.emplace_back(argv[i]);
            if (args.empty()) {
                std::fprintf(stderr, "usage: newtd <configure|serve|start|status|prepare|attach|command|run|bundle|resume|stop-game|stop|poll-host-requests> ...\n");
                return 2;
            }
            std::string command = args[0];
            std::vector<std::string> rest(args.begin() + 1, args.end());
            Paths paths = GetPaths();
            if (command == "configure") {
                return RunConfigure(paths.state, rest);
            }
            if (command == "serve") {
                return Serve(paths.state, paths.endpoint);
            }
            if (command == "bundle") {
                return RunBundle(rest);
            }
            NSDictionary* result = nil;
            if (command == "start") {
                result = EnsureSession(paths.state, paths.endpoint);
            } else if (command == "prepare") {
                bool noStart = std::find(rest.begin(), rest.end(), "--no-start") != rest.end();
                if (!noStart) (void)EnsureSession(paths.state, paths.endpoint);
                result = Request(paths.endpoint, @{@"action": @"prepare"});
            } else if (command == "attach") {
                NSString* token = FlagValue(rest, "--token");
                NSString* pid = FlagValue(rest, "--pid");
                if (token == nil || pid == nil) Fail("attach requires --token and --pid");
                result = Request(paths.endpoint, @{@"action": @"attach", @"token": token, @"pid": @(pid.intValue)});
            } else if (command == "command") {
                NSString* text = FlagValue(rest, "--text");
                if (text == nil) Fail("command requires --text");
                result = Request(paths.endpoint, @{@"action": @"command", @"command": text});
            } else if (command == "run") {
                NSDictionary* config = LoadConfig(paths.state);
                NSString* project = FlagValue(rest, "--project");
                NSString* game = FlagValue(rest, "--game");
                NSArray<NSString*>* launchArgv = nil;
                NSString* cwd = nil;
                NSString* godotFlag = FlagValue(rest, "--godot");
                if (project != nil) {
                    project = ProjectDir(project);
                    NSString* godot = godotFlag ?: ([config[@"godot"] isKindOfClass:NSString.class] ? config[@"godot"] : @"godot");
                    launchArgv = @[Executable(godot), @"--path", project];
                    cwd = project;
                } else if (game != nil) {
                    launchArgv = @[Executable(game)];
                    cwd = launchArgv.firstObject.stringByDeletingLastPathComponent;
                } else {
                    Fail("run requires --project or --game");
                }
                launchArgv = [launchArgv arrayByAddingObjectsFromArray:@[@"--xr-mode", @"on", @"--rendering-method",
                                                                          @"mobile", @"--rendering-driver", @"vulkan"]];
                (void)EnsureSession(paths.state, paths.endpoint);
                result = Request(paths.endpoint, @{@"action": @"launch", @"argv": launchArgv, @"cwd": cwd});
            } else if (command == "status" || command == "resume" || command == "stop-game" ||
                       command == "stop" || command == "poll-host-requests") {
                result = Request(paths.endpoint, @{@"action": NStr(command)});
            } else {
                Fail("Unknown command: " + command);
            }
            PrintResult(result);
            return ResultOk(result) ? 0 : 1;
        } catch (const NewtError& e) {
            std::fprintf(stderr, "Newt: %s\n", e.message.c_str());
            return 1;
        } catch (...) {
            std::fprintf(stderr, "Newt: Internal error\n");
            return 1;
        }
    }
}
