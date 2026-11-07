#!/usr/bin/env python3
"""Generate KitchenAid.xcodeproj from whatever is on disk.

    python3 -I scripts/make_xcodeproj.py

Why generated rather than hand-written. There is no Xcode in this container, so
a project file written by hand either opens or it does not, with nothing in
between and no way to find out here. Generating it from the file tree means the
structure is produced the same way every time, every UUID is derived from a
path rather than invented, and adding a month of new Swift files is one command
instead of hand-editing two entries per file.

The format deliberately mirrors Brandon's CFAL3 project, which is known to
open: `objectVersion = 56`, `compatibilityVersion = "Xcode 14.0"`, and one
explicit PBXFileReference plus PBXBuildFile per file.

Xcode 16 and later can replace all of that with a synchronized folder
(`PBXFileSystemSynchronizedRootGroup`, objectVersion 77), which would make this
script unnecessary — no per-file entries at all. That is the better end state
and it is NOT used here, on purpose: its exact required keys could not be
verified without an Xcode to try it in, and a project that will not open is a
worse failure than one that needs a script. Once this opens on his Mac, Xcode
offers the conversion itself, and that is the moment to take it.

IMPORTANT: once Brandon has changed build settings in Xcode's UI, Xcode owns
this file and re-running the script would discard those edits. From that point,
add files in Xcode or edit the pbxproj surgically. The script is for the first
build and for a from-scratch regeneration.
"""

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "KitchenAid"
BUNDLE_ID = "com.brandonkeeny.KitchenAid"
TEAM = "HHSFT2GD2H"
DEPLOYMENT = "17.0"

# Files referenced individually land flat in the bundle root, so a loader finds
# them with `Bundle.main.url(forResource:withExtension:)` and no subdirectory —
# the convention CFAL3's ContentLoader already uses.
FLAT_RESOURCES = ["Resources/ingredients.json"]

# A FOLDER reference is copied whole and keeps its directory, which is what
# lets the loader ask for `subdirectory: "Recipes"`. Referencing the eight
# recipe files individually would flatten them into the bundle root and that
# lookup would return nothing.
FOLDER_RESOURCES = ["Resources/Recipes"]

ASSET_CATALOGS = ["Assets.xcassets"]

FILETYPES = {
    ".swift": "sourcecode.swift",
    ".json": "text.json",
    ".plist": "text.plist.xml",
    ".md": "net.daringfireball.markdown",
}


def uid(*parts):
    """A stable 24-hex-character id derived from what it names.

    Derived, not random, so regenerating produces the same file and a diff
    shows only what actually changed.
    """
    h = hashlib.sha256("\u0000".join(parts).encode()).hexdigest()
    return h[:24].upper()


def swift_sources(target_dir):
    out = []
    base = os.path.join(ROOT, target_dir)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames
                             if d != "Resources" and not d.endswith(".xcassets"))
        for name in sorted(filenames):
            if name.endswith(".swift"):
                rel = os.path.relpath(os.path.join(dirpath, name), base)
                out.append(rel.replace(os.sep, "/"))
    return out


class Project:
    def __init__(self):
        self.lines = []
        self.app_sources = swift_sources(APP)
        self.test_sources = swift_sources(f"{APP}Tests")
        self.uitest_sources = swift_sources(f"{APP}UITests")

        # Targets
        self.t_app = uid("target", APP)
        self.t_tests = uid("target", f"{APP}Tests")
        self.t_uitests = uid("target", f"{APP}UITests")
        self.project = uid("project", APP)

        self.products_group = uid("group", "Products")
        self.main_group = uid("group", "main")

        self.ref_app = uid("product", f"{APP}.app")
        self.ref_tests = uid("product", f"{APP}Tests.xctest")
        self.ref_uitests = uid("product", f"{APP}UITests.xctest")

    # ---- emit helpers --------------------------------------------------
    def w(self, text=""):
        self.lines.append(text)

    def section(self, name, body):
        if not body:
            return
        self.w(f"/* Begin {name} section */")
        for line in body:
            self.w(line)
        self.w(f"/* End {name} section */")
        self.w()

    # ---- file references ------------------------------------------------
    def file_entries(self):
        """(group_dir, filename, file_ref_uid, build_uid, phase) per file."""
        entries = []
        for target, files, phase_target in (
            (APP, self.app_sources, "app"),
            (f"{APP}Tests", self.test_sources, "tests"),
            (f"{APP}UITests", self.uitest_sources, "uitests"),
        ):
            for rel in files:
                group_dir = os.path.dirname(rel)
                name = os.path.basename(rel)
                key = f"{target}/{rel}"
                entries.append({
                    "target": target, "rel": rel, "dir": group_dir, "name": name,
                    "ref": uid("ref", key), "build": uid("build", key),
                    "phase": phase_target, "kind": "source",
                    "type": FILETYPES.get(os.path.splitext(name)[1], "text"),
                })
        for rel in FLAT_RESOURCES + ASSET_CATALOGS:
            name = os.path.basename(rel)
            key = f"{APP}/{rel}"
            ftype = ("folder.assetcatalog" if name.endswith(".xcassets")
                     else FILETYPES.get(os.path.splitext(name)[1], "text"))
            entries.append({
                "target": APP, "rel": rel, "dir": os.path.dirname(rel), "name": name,
                "ref": uid("ref", key), "build": uid("build", key),
                "phase": "resources", "kind": "resource", "type": ftype,
            })
        for rel in FOLDER_RESOURCES:
            name = os.path.basename(rel)
            key = f"{APP}/{rel}"
            entries.append({
                "target": APP, "rel": rel, "dir": os.path.dirname(rel), "name": name,
                "ref": uid("ref", key), "build": uid("build", key),
                "phase": "resources", "kind": "folder", "type": "folder",
            })
        return entries

    # ---- groups ----------------------------------------------------------
    def build_groups(self, entries):
        """One PBXGroup per directory, mirroring the tree Xcode's navigator shows."""
        tree = {}
        for e in entries:
            parts = [e["target"]] + ([p for p in e["dir"].split("/") if p] if e["dir"] else [])
            node = tree
            for part in parts:
                node = node.setdefault(part, {"__files__": [], "__dirs__": {}})["__dirs__"] \
                    if False else node.setdefault(part, {"__files__": [], "__dirs__": {}})
                node = node  # keep reference
                node_files = node
                node = node["__dirs__"] if False else node
                break_outer = False
                # walk deeper manually below
                node = node_files
                node = node
                node = node
                node = node
                node = node
                node = node["__dirs__"] if False else node
                node = node
                node = node
                node = node
                break
            # the loop above is replaced by the explicit walk below
        # explicit, readable walk
        tree = {}
        for e in entries:
            parts = [e["target"]] + ([p for p in e["dir"].split("/") if p] if e["dir"] else [])
            node = tree
            for part in parts:
                node = node.setdefault(part, {"files": [], "dirs": {}})
                nxt = node["dirs"]
                node = node if part == parts[-1] else nxt
                if part != parts[-1]:
                    continue
            node["files"].append(e)

        def emit(name, node, path):
            gid = uid("group", path)
            children = []
            for sub in sorted(node["dirs"]):
                children.append(emit(sub, node["dirs"][sub], f"{path}/{sub}"))
            for f in sorted(node["files"], key=lambda x: x["name"]):
                children.append((f["ref"], f["name"]))
            kids = "\n".join(f"\t\t\t\t{cid} /* {cname} */," for cid, cname in children)
            self.group_bodies.append(
                f"\t\t{gid} /* {name} */ = {{\n"
                f"\t\t\tisa = PBXGroup;\n"
                f"\t\t\tchildren = (\n{kids}\n\t\t\t);\n"
                f"\t\t\tpath = {name};\n"
                f"\t\t\tsourceTree = \"<group>\";\n"
                f"\t\t}};"
            )
            return (gid, name)

        self.group_bodies = []
        tops = []
        for top in sorted(tree):
            tops.append(emit(top, tree[top], top))
        return tops


def dirs_for(entries):
    """Directory tree: {name: {"files": [...], "dirs": {...}}}"""
    tree = {}
    for e in entries:
        parts = [e["target"]] + [p for p in (e["dir"].split("/") if e["dir"] else []) if p]
        node = tree
        for i, part in enumerate(parts):
            node = node.setdefault(part, {"files": [], "dirs": {}})
            if i < len(parts) - 1:
                node = node["dirs"]
        node["files"].append(e)
    return tree


def emit_groups(tree, group_bodies, path_prefix=""):
    tops = []
    for name in sorted(tree):
        node = tree[name]
        path = f"{path_prefix}/{name}" if path_prefix else name
        gid = uid("group", path)
        children = []
        children += emit_groups(node["dirs"], group_bodies, path)
        for f in sorted(node["files"], key=lambda x: x["name"]):
            children.append((f["ref"], f["name"]))
        kids = "\n".join(f"\t\t\t\t{cid} /* {cname} */," for cid, cname in children)
        group_bodies.append(
            f"\t\t{gid} /* {name} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n{kids}\n\t\t\t);\n"
            f"\t\t\tpath = {name};\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};"
        )
        tops.append((gid, name))
    return tops


BASE_SETTINGS = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = %s;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
""" % DEPLOYMENT


def main():
    p = Project()
    entries = p.file_entries()

    refs = set(e["ref"] for e in entries)
    if len(refs) != len(entries):
        print("UUID collision between file references — bailing out rather than "
              "writing a project that silently drops a file", file=sys.stderr)
        sys.exit(1)

    # --- PBXBuildFile -----------------------------------------------------
    build_files = []
    for e in sorted(entries, key=lambda x: x["name"]):
        phase = "Resources" if e["phase"] == "resources" else "Sources"
        build_files.append(
            f"\t\t{e['build']} /* {e['name']} in {phase} */ = {{isa = PBXBuildFile; "
            f"fileRef = {e['ref']} /* {e['name']} */; }};")

    # --- PBXFileReference -------------------------------------------------
    file_refs = []
    for e in sorted(entries, key=lambda x: x["name"]):
        file_refs.append(
            f"\t\t{e['ref']} /* {e['name']} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = {e['type']}; path = {e['name']}; "
            f"sourceTree = \"<group>\"; }};")
    for rid, name, ftype in (
        (p.ref_app, f"{APP}.app", "wrapper.application"),
        (p.ref_tests, f"{APP}Tests.xctest", "wrapper.cfbundle"),
        (p.ref_uitests, f"{APP}UITests.xctest", "wrapper.cfbundle"),
    ):
        file_refs.append(
            f"\t\t{rid} /* {name} */ = {{isa = PBXFileReference; "
            f"explicitFileType = {ftype}; includeInIndex = 0; path = {name}; "
            f"sourceTree = BUILT_PRODUCTS_DIR; }};")

    # --- PBXGroup ---------------------------------------------------------
    group_bodies = []
    tops = emit_groups(dirs_for(entries), group_bodies)
    kids = "\n".join(f"\t\t\t\t{gid} /* {name} */," for gid, name in tops)
    group_bodies.append(
        f"\t\t{p.products_group} /* Products */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
        f"\t\t\t\t{p.ref_app} /* {APP}.app */,\n"
        f"\t\t\t\t{p.ref_tests} /* {APP}Tests.xctest */,\n"
        f"\t\t\t\t{p.ref_uitests} /* {APP}UITests.xctest */,\n"
        f"\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
    group_bodies.append(
        f"\t\t{p.main_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\n"
        f"\t\t\t\t{p.products_group} /* Products */,\n"
        f"\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")

    # --- build phases -----------------------------------------------------
    def phase(pid, isa, label, members):
        files = "\n".join(
            f"\t\t\t\t{e['build']} /* {e['name']} in {label} */," for e in members)
        return (f"\t\t{pid} /* {label} */ = {{\n\t\t\tisa = {isa};\n"
                f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{files}\n\t\t\t);\n"
                f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")

    src_app = uid("phase", "src-app")
    src_tests = uid("phase", "src-tests")
    src_uitests = uid("phase", "src-uitests")
    res_app = uid("phase", "res-app")
    fw_app = uid("phase", "fw-app")
    fw_tests = uid("phase", "fw-tests")
    fw_uitests = uid("phase", "fw-uitests")

    sources = [
        phase(src_app, "PBXSourcesBuildPhase", "Sources",
              [e for e in entries if e["phase"] == "app"]),
        phase(src_tests, "PBXSourcesBuildPhase", "Sources",
              [e for e in entries if e["phase"] == "tests"]),
        phase(src_uitests, "PBXSourcesBuildPhase", "Sources",
              [e for e in entries if e["phase"] == "uitests"]),
    ]
    resources = [phase(res_app, "PBXResourcesBuildPhase", "Resources",
                       [e for e in entries if e["phase"] == "resources"])]
    frameworks = [phase(fid, "PBXFrameworksBuildPhase", "Frameworks", [])
                  for fid in (fw_app, fw_tests, fw_uitests)]

    # --- dependencies ------------------------------------------------------
    proxy_tests = uid("proxy", "tests")
    proxy_uitests = uid("proxy", "uitests")
    dep_tests = uid("dep", "tests")
    dep_uitests = uid("dep", "uitests")
    proxies = [
        (f"\t\t{pid} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n"
         f"\t\t\tcontainerPortal = {p.project} /* Project object */;\n"
         f"\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {p.t_app};\n"
         f"\t\t\tremoteInfo = {APP};\n\t\t}};")
        for pid in (proxy_tests, proxy_uitests)]
    deps = [
        (f"\t\t{did} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n"
         f"\t\t\ttarget = {p.t_app} /* {APP} */;\n"
         f"\t\t\ttargetProxy = {pid} /* PBXContainerItemProxy */;\n\t\t}};")
        for did, pid in ((dep_tests, proxy_tests), (dep_uitests, proxy_uitests))]

    # --- targets -----------------------------------------------------------
    cl_app = uid("conflist", "app")
    cl_tests = uid("conflist", "tests")
    cl_uitests = uid("conflist", "uitests")
    cl_proj = uid("conflist", "project")

    targets = [
        (f"\t\t{p.t_app} /* {APP} */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
         f"\t\t\tbuildConfigurationList = {cl_app} /* Build configuration list for PBXNativeTarget \"{APP}\" */;\n"
         f"\t\t\tbuildPhases = (\n\t\t\t\t{src_app} /* Sources */,\n"
         f"\t\t\t\t{fw_app} /* Frameworks */,\n\t\t\t\t{res_app} /* Resources */,\n\t\t\t);\n"
         f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n"
         f"\t\t\tname = {APP};\n\t\t\tproductName = {APP};\n"
         f"\t\t\tproductReference = {p.ref_app} /* {APP}.app */;\n"
         f"\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};"),
        (f"\t\t{p.t_tests} /* {APP}Tests */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
         f"\t\t\tbuildConfigurationList = {cl_tests} /* Build configuration list for PBXNativeTarget \"{APP}Tests\" */;\n"
         f"\t\t\tbuildPhases = (\n\t\t\t\t{src_tests} /* Sources */,\n"
         f"\t\t\t\t{fw_tests} /* Frameworks */,\n\t\t\t);\n"
         f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n"
         f"\t\t\t\t{dep_tests} /* PBXTargetDependency */,\n\t\t\t);\n"
         f"\t\t\tname = {APP}Tests;\n\t\t\tproductName = {APP}Tests;\n"
         f"\t\t\tproductReference = {p.ref_tests} /* {APP}Tests.xctest */;\n"
         f"\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";\n\t\t}};"),
        (f"\t\t{p.t_uitests} /* {APP}UITests */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
         f"\t\t\tbuildConfigurationList = {cl_uitests} /* Build configuration list for PBXNativeTarget \"{APP}UITests\" */;\n"
         f"\t\t\tbuildPhases = (\n\t\t\t\t{src_uitests} /* Sources */,\n"
         f"\t\t\t\t{fw_uitests} /* Frameworks */,\n\t\t\t);\n"
         f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n"
         f"\t\t\t\t{dep_uitests} /* PBXTargetDependency */,\n\t\t\t);\n"
         f"\t\t\tname = {APP}UITests;\n\t\t\tproductName = {APP}UITests;\n"
         f"\t\t\tproductReference = {p.ref_uitests} /* {APP}UITests.xctest */;\n"
         f"\t\t\tproductType = \"com.apple.product-type.bundle.ui-testing\";\n\t\t}};"),
    ]

    project_obj = [
        (f"\t\t{p.project} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n"
         f"\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
         f"\t\t\t\tLastSwiftUpdateCheck = 2700;\n\t\t\t\tLastUpgradeCheck = 2700;\n"
         f"\t\t\t\tTargetAttributes = {{\n"
         f"\t\t\t\t\t{p.t_tests} = {{\n\t\t\t\t\t\tTestTargetID = {p.t_app};\n\t\t\t\t\t}};\n"
         f"\t\t\t\t\t{p.t_uitests} = {{\n\t\t\t\t\t\tTestTargetID = {p.t_app};\n\t\t\t\t\t}};\n"
         f"\t\t\t\t}};\n\t\t\t}};\n"
         f"\t\t\tbuildConfigurationList = {cl_proj} /* Build configuration list for PBXProject \"{APP}\" */;\n"
         f"\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n"
         f"\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
         f"\t\t\tmainGroup = {p.main_group};\n"
         f"\t\t\tproductRefGroup = {p.products_group} /* Products */;\n"
         f"\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n"
         f"\t\t\ttargets = (\n\t\t\t\t{p.t_app} /* {APP} */,\n"
         f"\t\t\t\t{p.t_tests} /* {APP}Tests */,\n"
         f"\t\t\t\t{p.t_uitests} /* {APP}UITests */,\n\t\t\t);\n\t\t}};")
    ]

    # --- build configurations ----------------------------------------------
    def conf(cid, name, extra):
        return (f"\t\t{cid} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n"
                f"\t\t\tbuildSettings = {{\n{extra}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};")

    proj_debug_extra = BASE_SETTINGS + ("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n"
                                        "\t\t\t\tENABLE_TESTABILITY = YES;\n"
                                        "\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n"
                                        "\t\t\t\tONLY_ACTIVE_ARCH = YES;\n"
                                        "\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";\n"
                                        "\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";\n")
    proj_release_extra = BASE_SETTINGS + ("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";\n"
                                          "\t\t\t\tENABLE_NS_ASSERTIONS = NO;\n"
                                          "\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n"
                                          "\t\t\t\tVALIDATE_PRODUCT = YES;\n")

    app_common = (
        f"\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n"
        f"\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;\n"
        f"\t\t\t\tCODE_SIGN_STYLE = Automatic;\n"
        f"\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n"
        f"\t\t\t\tDEVELOPMENT_ASSET_PATHS = \"\";\n"
        f"\t\t\t\tDEVELOPMENT_TEAM = {TEAM};\n"
        f"\t\t\t\tENABLE_PREVIEWS = YES;\n"
        f"\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n"
        f"\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = KitchenAid;\n"
        f"\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;\n"
        f"\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;\n"
        f"\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;\n"
        f"\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations = \"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";\n"
        f"\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = \"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";\n"
        f"\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t\t);\n"
        f"\t\t\t\tMARKETING_VERSION = 1.0;\n"
        f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};\n"
        f"\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n"
        f"\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n"
        f"\t\t\t\tSWIFT_VERSION = 5.0;\n"
        f"\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";\n")

    def test_common(suffix, ui):
        host = ("" if ui else
                f"\t\t\t\tBUNDLE_LOADER = \"$(TEST_HOST)\";\n"
                f"\t\t\t\tTEST_HOST = \"$(BUILT_PRODUCTS_DIR)/{APP}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{APP}\";\n")
        target_app = f"\t\t\t\tTEST_TARGET_NAME = {APP};\n" if ui else ""
        return (
            f"\t\t\t\tALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES;\n"
            f"{host}"
            f"\t\t\t\tCODE_SIGN_STYLE = Automatic;\n"
            f"\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n"
            f"\t\t\t\tDEVELOPMENT_TEAM = {TEAM};\n"
            f"\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n"
            f"\t\t\t\tMARKETING_VERSION = 1.0;\n"
            f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID}{suffix};\n"
            f"\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n"
            f"\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;\n"
            f"\t\t\t\tSWIFT_VERSION = 5.0;\n"
            f"\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";\n"
            f"{target_app}")

    c = {}
    for key, name, extra in (
        ("proj-debug", "Debug", proj_debug_extra),
        ("proj-release", "Release", proj_release_extra),
        ("app-debug", "Debug", app_common),
        ("app-release", "Release", app_common),
        ("tests-debug", "Debug", test_common("Tests", False)),
        ("tests-release", "Release", test_common("Tests", False)),
        ("uitests-debug", "Debug", test_common("UITests", True)),
        ("uitests-release", "Release", test_common("UITests", True)),
    ):
        c[key] = (uid("conf", key), name, extra)

    configs = [conf(cid, name, extra) for cid, name, extra in c.values()]

    def conflist(lid, label, debug_key, release_key):
        return (f"\t\t{lid} /* Build configuration list for {label} */ = {{\n"
                f"\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{c[debug_key][0]} /* Debug */,\n"
                f"\t\t\t\t{c[release_key][0]} /* Release */,\n\t\t\t);\n"
                f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
                f"\t\t\tdefaultConfigurationName = Release;\n\t\t}};")

    conflists = [
        conflist(cl_proj, f"PBXProject \"{APP}\"", "proj-debug", "proj-release"),
        conflist(cl_app, f"PBXNativeTarget \"{APP}\"", "app-debug", "app-release"),
        conflist(cl_tests, f"PBXNativeTarget \"{APP}Tests\"", "tests-debug", "tests-release"),
        conflist(cl_uitests, f"PBXNativeTarget \"{APP}UITests\"", "uitests-debug", "uitests-release"),
    ]

    # --- assemble -----------------------------------------------------------
    p.w("// !$*UTF8*$!")
    p.w("{")
    p.w("\tarchiveVersion = 1;")
    p.w("\tclasses = {")
    p.w("\t};")
    p.w("\tobjectVersion = 56;")
    p.w("\tobjects = {")
    p.w()
    p.section("PBXBuildFile", build_files)
    p.section("PBXContainerItemProxy", proxies)
    p.section("PBXFileReference", file_refs)
    p.section("PBXFrameworksBuildPhase", frameworks)
    p.section("PBXGroup", group_bodies)
    p.section("PBXNativeTarget", targets)
    p.section("PBXProject", project_obj)
    p.section("PBXResourcesBuildPhase", resources)
    p.section("PBXSourcesBuildPhase", sources)
    p.section("PBXTargetDependency", deps)
    p.section("XCBuildConfiguration", configs)
    p.section("XCConfigurationList", conflists)
    p.w("\t};")
    p.w(f"\trootObject = {p.project} /* Project object */;")
    p.w("}")

    proj_dir = os.path.join(ROOT, f"{APP}.xcodeproj")
    os.makedirs(proj_dir, exist_ok=True)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(p.lines) + "\n")

    # --- shared scheme, so a fresh clone opens with something runnable ------
    schemes = os.path.join(proj_dir, "xcshareddata", "xcschemes")
    os.makedirs(schemes, exist_ok=True)
    with open(os.path.join(schemes, f"{APP}.xcscheme"), "w", encoding="utf-8") as fh:
        fh.write(SCHEME.format(app=APP, app_target=p.t_app, tests_target=p.t_tests,
                               uitests_target=p.t_uitests))

    print(f"wrote {APP}.xcodeproj  "
          f"({len(p.app_sources)} app sources, {len(p.test_sources)} unit tests, "
          f"{len(p.uitest_sources)} UI tests, "
          f"{len([e for e in entries if e['phase'] == 'resources'])} resources)")


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{app}.app" BlueprintName = "{app}" ReferencedContainer = "container:{app}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <TestPlans>
      </TestPlans>
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{tests_target}" BuildableName = "{app}Tests.xctest" BlueprintName = "{app}Tests" ReferencedContainer = "container:{app}.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{uitests_target}" BuildableName = "{app}UITests.xctest" BlueprintName = "{app}UITests" ReferencedContainer = "container:{app}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{app}.app" BlueprintName = "{app}" ReferencedContainer = "container:{app}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{app}.app" BlueprintName = "{app}" ReferencedContainer = "container:{app}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


if __name__ == "__main__":
    main()
