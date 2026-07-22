"""Validate packaged PE imports against the current RTM guest.

This module deliberately uses only pure Python.  It must be able to inspect
the remaining native modules even when loading one of those modules would
terminate the process with a missing-entry-point error.
"""

import os
import sys


class PEFormatError(ValueError):
    pass


class PEImage:
    def __init__(self, path):
        self.path = os.path.abspath(path)
        with open(self.path, "rb") as stream:
            self.data = stream.read()

        if len(self.data) < 0x40 or self.data[:2] != b"MZ":
            raise PEFormatError(f"{self.path}: missing DOS header")
        pe_offset = self._unpack_from("<I", 0x3C)[0]
        if self._slice(pe_offset, 4) != b"PE\0\0":
            raise PEFormatError(f"{self.path}: missing PE signature")

        file_header = pe_offset + 4
        self.machine, section_count = self._unpack_from("<HH", file_header)
        optional_size = self._unpack_from("<H", file_header + 16)[0]
        optional = file_header + 20
        magic = self._unpack_from("<H", optional)[0]
        if magic == 0x10B:
            self.pointer_size = 4
            self.image_base = self._unpack_from("<I", optional + 28)[0]
            directory_offset = optional + 96
        elif magic == 0x20B:
            self.pointer_size = 8
            self.image_base = self._unpack_from("<Q", optional + 24)[0]
            directory_offset = optional + 112
        else:
            raise PEFormatError(f"{self.path}: unsupported optional-header magic {magic:#x}")

        self.size_of_headers = self._unpack_from("<I", optional + 60)[0]
        self.subsystem_version = self._unpack_from("<HH", optional + 48)
        directory_count = self._unpack_from("<I", directory_offset - 4)[0]
        self.directories = []
        for index in range(min(directory_count, 16)):
            self.directories.append(
                self._unpack_from("<II", directory_offset + index * 8)
            )
        while len(self.directories) < 16:
            self.directories.append((0, 0))

        section_offset = optional + optional_size
        self.sections = []
        for index in range(section_count):
            entry = section_offset + index * 40
            virtual_size, virtual_address, raw_size, raw_offset = self._unpack_from(
                "<IIII", entry + 8
            )
            self.sections.append(
                (virtual_address, max(virtual_size, raw_size), raw_offset, raw_size)
            )

    def _slice(self, offset, size):
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise PEFormatError(f"{self.path}: truncated PE data at {offset:#x}")
        return self.data[offset:offset + size]

    def _unpack_from(self, fmt, offset):
        if not fmt.startswith("<"):
            raise PEFormatError(f"unsupported PE integer format {fmt!r}")
        widths = {"H": 2, "I": 4, "Q": 8}
        values = []
        for code in fmt[1:]:
            try:
                width = widths[code]
            except KeyError:
                raise PEFormatError(f"unsupported PE integer format {fmt!r}")
            values.append(int.from_bytes(self._slice(offset, width), "little"))
            offset += width
        return tuple(values)

    def _rva_offset(self, rva):
        if rva < self.size_of_headers and rva < len(self.data):
            return rva
        for virtual_address, virtual_size, raw_offset, raw_size in self.sections:
            if virtual_address <= rva < virtual_address + virtual_size:
                delta = rva - virtual_address
                if delta >= raw_size:
                    break
                return raw_offset + delta
        raise PEFormatError(f"{self.path}: unmapped RVA {rva:#x}")

    def _cstring(self, offset):
        end = self.data.find(b"\0", offset)
        if end < 0:
            raise PEFormatError(f"{self.path}: unterminated string at {offset:#x}")
        return self._slice(offset, end - offset).decode("ascii")

    def _rva_string(self, rva):
        return self._cstring(self._rva_offset(rva))

    def _read_thunks(self, table_rva):
        if not table_rva:
            return []
        offset = self._rva_offset(table_rva)
        fmt = "<Q" if self.pointer_size == 8 else "<I"
        ordinal_flag = 1 << (self.pointer_size * 8 - 1)
        step = self.pointer_size
        imports = []
        for index in range(1_000_000):
            value = self._unpack_from(fmt, offset + index * step)[0]
            if value == 0:
                return imports
            if value & ordinal_flag:
                imports.append(value & 0xFFFF)
            else:
                name_offset = self._rva_offset(value) + 2
                imports.append(self._cstring(name_offset))
        raise PEFormatError(f"{self.path}: unterminated import thunk table")

    def imports(self):
        result = []
        import_rva, _ = self.directories[1]
        if import_rva:
            offset = self._rva_offset(import_rva)
            for index in range(100_000):
                descriptor = self._unpack_from("<IIIII", offset + index * 20)
                if not any(descriptor):
                    break
                original_thunk, _, _, name_rva, first_thunk = descriptor
                dll = self._rva_string(name_rva)
                for symbol in self._read_thunks(original_thunk or first_thunk):
                    result.append((dll, symbol, False))
            else:
                raise PEFormatError(f"{self.path}: unterminated import directory")

        delay_rva, _ = self.directories[13]
        if delay_rva:
            offset = self._rva_offset(delay_rva)
            for index in range(100_000):
                descriptor = self._unpack_from("<IIIIIIII", offset + index * 32)
                if not any(descriptor):
                    break
                attributes, name_value, _, _, name_table, _, _, _ = descriptor
                values_are_rvas = bool(attributes & 1)
                if values_are_rvas:
                    name_rva = name_value
                    table_rva = name_table
                else:
                    name_rva = name_value - self.image_base
                    table_rva = name_table - self.image_base
                dll = self._rva_string(name_rva)
                for symbol in self._read_thunks(table_rva):
                    result.append((dll, symbol, True))
            else:
                raise PEFormatError(f"{self.path}: unterminated delay-import directory")
        return result

    def exports(self):
        export_rva, export_size = self.directories[0]
        if not export_rva:
            return {}
        offset = self._rva_offset(export_rva)
        fields = self._unpack_from("<IIHHIIIIIII", offset)
        ordinal_base = fields[5]
        function_count = fields[6]
        name_count = fields[7]
        functions_rva = fields[8]
        names_rva = fields[9]
        ordinals_rva = fields[10]

        by_index = {}
        functions_offset = self._rva_offset(functions_rva)
        for index in range(function_count):
            function_rva = self._unpack_from("<I", functions_offset + index * 4)[0]
            if not function_rva:
                continue
            forwarder = None
            if export_rva <= function_rva < export_rva + export_size:
                forwarder = self._rva_string(function_rva)
            by_index[index] = forwarder

        result = {ordinal_base + index: target for index, target in by_index.items()}
        names_offset = self._rva_offset(names_rva) if name_count else 0
        ordinals_offset = self._rva_offset(ordinals_rva) if name_count else 0
        for index in range(name_count):
            name_rva = self._unpack_from("<I", names_offset + index * 4)[0]
            function_index = self._unpack_from("<H", ordinals_offset + index * 2)[0]
            if function_index in by_index:
                result[self._rva_string(name_rva)] = by_index[function_index]
        return result


def _binary_paths(package_root):
    for directory, _, filenames in os.walk(package_root):
        for filename in filenames:
            if os.path.splitext(filename)[1].lower() in (".dll", ".exe", ".pyd"):
                yield os.path.join(directory, filename)


def _normalized_directory(path):
    return os.path.normcase(os.path.abspath(path))


def _declared_dll_directories(package_root):
    directories = set()
    path_value = os.environ.get("PATH", "")
    for entry in path_value.split(os.pathsep):
        if entry:
            directories.add(_normalized_directory(entry))

    # These are the conventional private DLL directories used by pywin32 and
    # by wheels repaired with delvewheel.  They are activated by package
    # bootstrap code before the corresponding extension modules are imported.
    for directory, dirnames, _ in os.walk(package_root):
        for dirname in dirnames:
            lowered = dirname.lower()
            if lowered == "pywin32_system32" or lowered.endswith(".libs"):
                directories.add(_normalized_directory(os.path.join(directory, dirname)))

    declaration = os.path.join(package_root, "RTM-DLL-DIRECTORIES.txt")
    if os.path.isfile(declaration):
        with open(declaration, "r", encoding="utf-8-sig") as stream:
            for line_number, line in enumerate(stream, 1):
                relative = line.strip()
                if not relative or relative.startswith("#"):
                    continue
                candidate = os.path.abspath(os.path.join(package_root, relative))
                try:
                    common = os.path.commonpath((package_root, candidate))
                except ValueError:
                    common = ""
                if os.path.normcase(common) != os.path.normcase(package_root):
                    raise AssertionError(
                        f"{declaration}:{line_number}: DLL directory escapes package root"
                    )
                if not os.path.isdir(candidate):
                    raise AssertionError(
                        f"{declaration}:{line_number}: DLL directory does not exist: "
                        f"{relative}"
                    )
                directories.add(_normalized_directory(candidate))
    return directories


def validate_package(package_root=None):
    package_root = os.path.abspath(package_root or os.path.dirname(sys.executable))
    binary_paths = sorted(_binary_paths(package_root), key=os.path.normcase)
    packaged = {}
    for path in binary_paths:
        packaged.setdefault(os.path.basename(path).upper(), []).append(path)
    system_root = os.environ.get("SystemRoot")
    if not system_root:
        raise AssertionError("SystemRoot is not set")
    system_directory = os.path.join(system_root, "System32")
    image_cache = {}
    export_cache = {}
    failures = []
    checked_imports = 0
    expected_machine = 0x8664 if sys.maxsize > 2**32 else 0x014C
    searchable_directories = _declared_dll_directories(package_root)
    searchable_directories.add(_normalized_directory(package_root))

    def relative(path):
        return os.path.relpath(path, package_root).replace("\\", "/")

    def dependency_path(dll, importer_path):
        candidates = packaged.get(dll.upper(), ())
        importer_directory = _normalized_directory(os.path.dirname(importer_path))
        application_directory = _normalized_directory(package_root)
        local = [
            path for path in candidates
            if (_normalized_directory(os.path.dirname(path)) == importer_directory or
                _normalized_directory(os.path.dirname(path)) == application_directory)
        ]
        if local:
            return sorted(local, key=os.path.normcase)[0], None
        path = os.path.join(system_directory, dll)
        if os.path.isfile(path):
            return path, None
        private = [
            path for path in candidates
            if _normalized_directory(os.path.dirname(path)) in searchable_directories
        ]
        if private:
            return sorted(private, key=os.path.normcase)[0], None
        if candidates:
            locations = ", ".join(relative(path) for path in candidates)
            return None, (
                f"packaged dependency {dll} is not in the importing binary's "
                f"directory, the application directory, PATH, a conventional private "
                f"DLL directory, or RTM-DLL-DIRECTORIES.txt: {locations}"
            )
        return None, f"missing dependency {dll}"

    def image(path):
        normalized = os.path.normcase(os.path.abspath(path))
        if normalized not in image_cache:
            image_cache[normalized] = PEImage(path)
        return image_cache[normalized]

    def exports(path):
        normalized = os.path.normcase(os.path.abspath(path))
        if normalized not in export_cache:
            export_cache[normalized] = image(path).exports()
        return export_cache[normalized]

    def resolve_export(dll, symbol, chain, importer_path):
        path, lookup_failure = dependency_path(dll, importer_path)
        label = f"{dll}!{symbol}"
        if not path:
            return lookup_failure
        key = (os.path.normcase(os.path.abspath(path)), symbol)
        if key in chain:
            return f"forwarder cycle at {label}"
        available = exports(path)
        if symbol not in available:
            return f"missing export {label}"
        forwarder = available[symbol]
        if not forwarder:
            return None
        if "." not in forwarder:
            return f"invalid forwarder {label} -> {forwarder}"
        target_dll, target_symbol = forwarder.rsplit(".", 1)
        if not target_dll.lower().endswith(".dll"):
            target_dll += ".dll"
        if target_symbol.startswith("#"):
            try:
                target_symbol = int(target_symbol[1:])
            except ValueError:
                return f"invalid ordinal forwarder {label} -> {forwarder}"
        return resolve_export(target_dll, target_symbol, chain | {key}, path)

    # Never collapse duplicate basenames.  Identical copies are harmless and
    # are all inspected; differing copies are loader-order dependent and must
    # be rejected before any extension module is imported.
    for binary_name, paths in sorted(packaged.items()):
        if len(paths) < 2:
            continue
        try:
            first_data = image(paths[0]).data
            if any(image(path).data != first_data for path in paths[1:]):
                failures.append(
                    f"{binary_name}: conflicting duplicate binaries: " +
                    ", ".join(relative(path) for path in paths)
                )
        except (OSError, PEFormatError) as error:
            failures.append(
                f"{binary_name}: could not compare duplicate binaries: {error}"
            )

    for binary_path in binary_paths:
        binary_name = relative(binary_path)
        try:
            binary = image(binary_path)
            if binary.machine != expected_machine:
                failures.append(
                    f"{binary_name}: machine {binary.machine:#x} does not match "
                    f"the running interpreter ({expected_machine:#x})"
                )
            if (os.path.splitext(binary_path)[1].lower() == ".exe" and
                    binary.subsystem_version > (6, 0)):
                failures.append(
                    f"{binary_name}: subsystem version "
                    f"{binary.subsystem_version[0]}.{binary.subsystem_version[1]} "
                    "is newer than Vista RTM 6.0"
                )
            for dll, symbol, delayed in binary.imports():
                checked_imports += 1
                failure = resolve_export(dll, symbol, set(), binary_path)
                if failure:
                    kind = "delay import" if delayed else "import"
                    failures.append(f"{binary_name}: {kind} {dll}!{symbol}: {failure}")
        except (OSError, PEFormatError) as error:
            failures.append(f"{binary_name}: could not inspect PE image: {error}")

    if failures:
        raise AssertionError(
            "RTM PE import preflight failed:\n  " + "\n  ".join(sorted(set(failures)))
        )
    result = {
        "event": "rtm-pe-preflight-passed",
        "binaries": len(binary_paths),
        "imports": checked_imports,
        "system_directory": system_directory,
    }
    print(
        "RTM PE import preflight passed: "
        f"{result['binaries']} binaries, {result['imports']} imports"
    )
    return result


if __name__ == "__main__":
    validate_package()
