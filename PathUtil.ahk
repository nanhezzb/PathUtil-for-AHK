#Requires AutoHotkey v2.0

; ============================================================
; PathUtil
; Version: 1.1.2
; Build Time: 2026-06-10 11:15
; ============================================================
;
; 功能:
;   AutoHotkey v2 的 Windows 路径同一性比较与规范化工具库。
;
; 说明:
;   Windows 下同一个文件或目录可能存在多种字符串写法，例如：
;   1. 短路径 / 长路径
;   2. 环境变量路径
;   3. AHK 内置变量名字面路径
;   4. 相对路径 / 绝对路径
;   5. 大小写差异
;   6. 符号链接 / Junction / 硬链接
;
;   本库提供两个层次的能力：
;   1. 字符串层：
;      通过 Normalize() 把路径统一规范化，再做大小写不敏感比较。
;   2. 文件系统层：
;      通过卷序列号 + 文件 ID 判断两个路径是否指向同一物理文件或目录。
;
; 使用方法:
;   #Include "D:\Program Files\AutoHotkey\lib\PathUtil.ahk"
;   或放到 Lib 目录后：
;   #Include <PathUtil>
;
;   示例:
;   result := PathUtil.IsEqual("C:\PROGRA~1", "%ProgramFiles%")
; ============================================================

class PathUtil {

    ; ============================================================
    ; Win32 API 常量
    ; ============================================================

    ; ------------------------------------------------------------
    ; CreateFile 标志
    ; ------------------------------------------------------------
    static FILE_ATTRIBUTE_NORMAL := 0x00000080
    static FILE_FLAG_BACKUP_SEMANTICS := 0x02000000
    static FILE_SHARE_READ_WRITE_DELETE := 0x00000007
    static OPEN_EXISTING := 3
    static INVALID_HANDLE_VALUE := -1

    ; ------------------------------------------------------------
    ; BY_HANDLE_FILE_INFORMATION 结构体字段偏移
    ; 结构体布局:
    ;   0  ~ 3   dwFileAttributes
    ;   4  ~ 11  ftCreationTime
    ;   12 ~ 19  ftLastAccessTime
    ;   20 ~ 27  ftLastWriteTime
    ;   28 ~ 31  dwVolumeSerialNumber
    ;   32 ~ 35  nFileSizeHigh
    ;   36 ~ 39  nFileSizeLow
    ;   40 ~ 43  nNumberOfLinks
    ;   44 ~ 47  nFileIndexHigh
    ;   48 ~ 51  nFileIndexLow
    ; ------------------------------------------------------------
    static OFFSET_VOLUME_SERIAL_NUMBER := 28
    static OFFSET_FILE_INDEX_HIGH := 44
    static OFFSET_FILE_INDEX_LOW := 48
    static SIZE_FILE_INFORMATION := 52

    ; ------------------------------------------------------------
    ; 路径前缀字符串
    ; ------------------------------------------------------------
    static PREFIX_EXTENDED := "\\?\"
    static PREFIX_EXTENDED_UNC := "\\?\UNC\"
    static PREFIX_UNC := "\\"

    ; ============================================================
    ; AHk 内置变量映射缓存
    ; ============================================================

    ; ------------------------------------------------------------
    ; _ahkVariableMap
    ; 功能:
    ;   缓存支持展开的 AHK 内置变量映射表。
    ; 说明:
    ;   首次访问时由 _GetAhkVariableMap() 延迟构建。
    ; ------------------------------------------------------------
    static _ahkVariableMap := ""

    ; ============================================================
    ; 公共 API
    ; ============================================================

    ; ------------------------------------------------------------
    ; Normalize
    ; 功能:
    ;   把任意 Windows 路径规范化为可比较的字符串形式。
    ; 处理顺序:
    ;   1. 展开开头的 ~
    ;   2. 展开 AHK 内置变量名字面字符串
    ;   3. 展开 %VAR% 环境变量
    ;   4. 统一分隔符
    ;   5. 相对路径转绝对路径
    ;   6. 短路径转长路径
    ;   7. 解析符号链接 / Junction，并应用磁盘真实大小写
    ;   8. 去掉 \\?\ 前缀
    ;   9. 去掉末尾分隔符（盘符根目录除外）
    ; 返回:
    ;   返回规范化后的路径字符串。
    ;   输入为空时返回空字符串。
    ; ------------------------------------------------------------
    static Normalize(path) {
        if (path = "")
            return ""

        path := this._ExpandTilde(path)
        path := this._ExpandAhkVariables(path)
        path := this._ExpandEnvironmentVariables(path)
        path := this._UnifySeparators(path)
        path := this._ConvertToAbsolute(path)
        path := this._ConvertShortToLong(path)
        path := this._ResolveFinalPath(path)
        path := this._StripExtendedPrefix(path)
        path := this._TrimTrailingSeparator(path)

        return path
    }

    ; ------------------------------------------------------------
    ; IsEqual
    ; 功能:
    ;   在字符串层面比较两个路径是否同一。
    ; 说明:
    ;   两个路径会先经过 Normalize()，再做大小写不敏感比较。
    ;   这是推荐的通用比较方法，即使路径不存在也可使用。
    ; 局限:
    ;   无法识别硬链接。
    ;   如果需要识别硬链接，请使用 IsSameFile()。
    ; ------------------------------------------------------------
    static IsEqual(pathA, pathB) {
        normalizedA := this.Normalize(pathA)
        normalizedB := this.Normalize(pathB)
        return StrCompare(normalizedA, normalizedB, false) = 0
    }

    ; ------------------------------------------------------------
    ; IsSameFile
    ; 功能:
    ;   在文件系统层面比较两个路径是否指向同一物理文件或目录。
    ; 说明:
    ;   通过卷序列号 + 文件索引判断同一性，可穿透：
    ;   1. 硬链接
    ;   2. 符号链接
    ;   3. Junction
    ; 要求:
    ;   两个路径都必须真实存在且能被打开，否则返回 false。
    ; ------------------------------------------------------------
    static IsSameFile(pathA, pathB) {
        infoA := this._GetFileIdentity(pathA)
        infoB := this._GetFileIdentity(pathB)

        if (!infoA || !infoB)
            return false

        return infoA.volumeSerial = infoB.volumeSerial
            && infoA.indexHigh = infoB.indexHigh
            && infoA.indexLow = infoB.indexLow
    }

    ; ------------------------------------------------------------
    ; IsEqualEx
    ; 功能:
    ;   综合比较两个路径是否同一。
    ; 策略:
    ;   1. 优先尝试文件系统层比较。
    ;   2. 如果文件系统层无法判断，则退回字符串层比较。
    ; ------------------------------------------------------------
    static IsEqualEx(pathA, pathB) {
        if (this.IsSameFile(pathA, pathB))
            return true

        return this.IsEqual(pathA, pathB)
    }

    ; ------------------------------------------------------------
    ; IsAbsolute
    ; 功能:
    ;   判断路径是否为绝对路径。
    ; 返回:
    ;   以盘符根路径或 UNC 路径开头返回 true，否则 false。
    ; ------------------------------------------------------------
    static IsAbsolute(path) {
        if (path = "")
            return false

        if (RegExMatch(path, "i)^[A-Za-z]:\\"))
            return true

        if (SubStr(path, 1, 2) = PathUtil.PREFIX_UNC)
            return true

        return false
    }

    ; ============================================================
    ; 内部方法：AHK 内置变量缓存
    ; ============================================================

    ; ------------------------------------------------------------
    ; _GetAhkVariableMap
    ; 功能:
    ;   获取 AHK 内置变量映射表。
    ; 说明:
    ;   首次调用时构建，后续复用缓存。
    ;   变量名按长度倒序排列，避免短名称先替换破坏长名称。
    ; 修正:
    ;   v1.1.1 改为使用 IsObject() 判断缓存是否已构建。
    ; ------------------------------------------------------------
    static _GetAhkVariableMap() {
        if IsObject(this._ahkVariableMap) {
            return this._ahkVariableMap
        }

        rawEntries := [
            ["A_AppDataCommon", A_AppDataCommon],
            ["A_AppData", A_AppData],
            ["A_DesktopCommon", A_DesktopCommon],
            ["A_Desktop", A_Desktop],
            ["A_MyDocuments", A_MyDocuments],
            ["A_ProgramsCommon", A_ProgramsCommon],
            ["A_Programs", A_Programs],
            ["A_StartupCommon", A_StartupCommon],
            ["A_Startup", A_Startup],
            ["A_Temp", A_Temp],
            ["A_WinDir", A_WinDir],
            ["A_WorkingDir", A_WorkingDir],
            ["A_ScriptFullPath", A_ScriptFullPath],
            ["A_ScriptDir", A_ScriptDir],
            ["A_ScriptName", A_ScriptName],
            ["A_UserName", A_UserName],
            ["A_ComputerName", A_ComputerName]
        ]

        n := rawEntries.Length

        loop n - 1 {
            outerIndex := A_Index

            loop n - outerIndex {
                innerIndex := A_Index

                if (StrLen(rawEntries[innerIndex][1]) < StrLen(rawEntries[innerIndex + 1][1])) {
                    temp := rawEntries[innerIndex]
                    rawEntries[innerIndex] := rawEntries[innerIndex + 1]
                    rawEntries[innerIndex + 1] := temp
                }
            }
        }

        this._ahkVariableMap := rawEntries
        return this._ahkVariableMap
    }

    ; ============================================================
    ; 内部方法：规范化流水线
    ; ============================================================

    ; ------------------------------------------------------------
    ; _ExpandTilde
    ; 功能:
    ;   展开开头的 ~ 为用户主目录。
    ; 说明:
    ;   仅处理:
    ;   1. ~
    ;   2. ~\...
    ;   3. ~/...
    ;   ~username 形式在 Windows 下不处理。
    ; ------------------------------------------------------------
    static _ExpandTilde(path) {
        if (SubStr(path, 1, 1) != "~")
            return path

        userProfile := EnvGet("USERPROFILE")

        if (userProfile = "")
            return path

        remainder := SubStr(path, 2)

        if (remainder = "")
            return userProfile

        firstChar := SubStr(remainder, 1, 1)

        if (firstChar != "\" && firstChar != "/")
            return path

        return userProfile . remainder
    }

    ; ------------------------------------------------------------
    ; _ExpandAhkVariables
    ; 功能:
    ;   展开路径字符串中的 AHK 内置变量名字面值。
    ; 说明:
    ;   例如把字符串里的 A_AppData 替换成实际目录。
    ;   适用于配置文件、命令行参数、日志中读出的路径模板。
    ; ------------------------------------------------------------
    static _ExpandAhkVariables(path) {
        variableMap := this._GetAhkVariableMap()

        for _, entry in variableMap {
            variableName := entry[1]
            variableValue := entry[2]

            if (InStr(path, variableName))
                path := StrReplace(path, variableName, variableValue)
        }

        return path
    }

    ; ------------------------------------------------------------
    ; _ExpandEnvironmentVariables
    ; 功能:
    ;   展开 %VAR% 形式的环境变量。
    ; 说明:
    ;   调用 ExpandEnvironmentStringsW。
    ;   失败时返回原路径。
    ; ------------------------------------------------------------
    static _ExpandEnvironmentVariables(path) {
        requiredSize := DllCall("ExpandEnvironmentStrings"
            , "Str", path
            , "Ptr", 0
            , "UInt", 0
            , "UInt")

        if (requiredSize = 0)
            return path

        buf := Buffer(requiredSize * 2, 0)

        success := DllCall("ExpandEnvironmentStrings"
            , "Str", path
            , "Ptr", buf
            , "UInt", requiredSize
            , "UInt")

        if (!success)
            return path

        return StrGet(buf, "UTF-16")
    }

    ; ------------------------------------------------------------
    ; _UnifySeparators
    ; 功能:
    ;   统一路径分隔符。
    ; 说明:
    ;   1. 把 / 替换为 \
    ;   2. 合并连续的 \
    ;   3. 保留 UNC 前缀和 \\?\ 前缀
    ; ------------------------------------------------------------
    static _UnifySeparators(path) {
        path := StrReplace(path, "/", "\")

        preservedPrefix := ""

        if (SubStr(path, 1, 4) = PathUtil.PREFIX_EXTENDED) {
            preservedPrefix := PathUtil.PREFIX_EXTENDED
            path := SubStr(path, 5)
        } else if (SubStr(path, 1, 2) = PathUtil.PREFIX_UNC) {
            preservedPrefix := PathUtil.PREFIX_UNC
            path := SubStr(path, 3)
        }

        while (InStr(path, "\\"))
            path := StrReplace(path, "\\", "\")

        return preservedPrefix . path
    }

    ; ------------------------------------------------------------
    ; _ConvertToAbsolute
    ; 功能:
    ;   把相对路径转为绝对路径，并解析 . 和 ..。
    ; 说明:
    ;   调用 GetFullPathNameW。
    ;   不要求路径在磁盘上存在。
    ; ------------------------------------------------------------
    static _ConvertToAbsolute(path) {
        requiredSize := DllCall("GetFullPathName"
            , "Str", path
            , "UInt", 0
            , "Ptr", 0
            , "Ptr", 0
            , "UInt")

        if (requiredSize = 0)
            return path

        buf := Buffer(requiredSize * 2, 0)

        success := DllCall("GetFullPathName"
            , "Str", path
            , "UInt", requiredSize
            , "Ptr", buf
            , "Ptr", 0
            , "UInt")

        if (!success)
            return path

        return StrGet(buf, "UTF-16")
    }

    ; ------------------------------------------------------------
    ; _ConvertShortToLong
    ; 功能:
    ;   把 8.3 短路径段转为完整长路径。
    ; 说明:
    ;   调用 GetLongPathNameW。
    ;   要求路径存在，否则回退为原路径。
    ; ------------------------------------------------------------
    static _ConvertShortToLong(path) {
        requiredSize := DllCall("GetLongPathName"
            , "Str", path
            , "Ptr", 0
            , "UInt", 0
            , "UInt")

        if (requiredSize = 0)
            return path

        buf := Buffer(requiredSize * 2, 0)

        success := DllCall("GetLongPathName"
            , "Str", path
            , "Ptr", buf
            , "UInt", requiredSize
            , "UInt")

        if (!success)
            return path

        return StrGet(buf, "UTF-16")
    }

    ; ------------------------------------------------------------
    ; _ResolveFinalPath
    ; 功能:
    ;   解析符号链接、Junction，并应用磁盘上的真实大小写。
    ; 说明:
    ;   调用 GetFinalPathNameByHandleW。
    ;   要求路径存在，否则回退为原路径。
    ; ------------------------------------------------------------
    static _ResolveFinalPath(path) {
        handle := this._OpenPathHandle(path)

        if (handle = PathUtil.INVALID_HANDLE_VALUE)
            return path

        try {
            requiredSize := DllCall("GetFinalPathNameByHandleW"
                , "Ptr", handle
                , "Ptr", 0
                , "UInt", 0
                , "UInt", 0
                , "UInt")

            if (requiredSize = 0)
                return path

            buf := Buffer(requiredSize * 2, 0)

            written := DllCall("GetFinalPathNameByHandleW"
                , "Ptr", handle
                , "Ptr", buf
                , "UInt", requiredSize
                , "UInt", 0
                , "UInt")

            if (!written)
                return path

            return StrGet(buf, "UTF-16")
        } finally {
            DllCall("CloseHandle", "Ptr", handle)
        }
    }

    ; ------------------------------------------------------------
    ; _StripExtendedPrefix
    ; 功能:
    ;   去除扩展长度路径前缀 \\?\。
    ; 说明:
    ;   支持:
    ;   1. \\?\C:\foo -> C:\foo
    ;   2. \\?\UNC\server\share -> \\server\share
    ; ------------------------------------------------------------
    static _StripExtendedPrefix(path) {
        if (SubStr(path, 1, 8) = PathUtil.PREFIX_EXTENDED_UNC)
            return PathUtil.PREFIX_UNC . SubStr(path, 9)

        if (SubStr(path, 1, 4) = PathUtil.PREFIX_EXTENDED)
            return SubStr(path, 5)

        return path
    }

    ; ------------------------------------------------------------
    ; _TrimTrailingSeparator
    ; 功能:
    ;   去掉路径末尾的反斜杠，但保留盘符根目录。
    ; 说明:
    ;   例如:
    ;   C:\foo\ -> C:\foo
    ;   C:\     -> C:\
    ; ------------------------------------------------------------
    static _TrimTrailingSeparator(path) {
        if (StrLen(path) > 3 && SubStr(path, -1) = "\")
            return RTrim(path, "\")

        return path
    }

    ; ============================================================
    ; 内部方法：文件系统辅助
    ; ============================================================

    ; ------------------------------------------------------------
    ; _GetFileIdentity
    ; 功能:
    ;   获取路径的卷序列号和文件索引。
    ; 返回:
    ;   成功返回对象:
    ;     { volumeSerial, indexHigh, indexLow }
    ;   失败返回空字符串。
    ; ------------------------------------------------------------
    static _GetFileIdentity(path) {
        handle := this._OpenPathHandle(path)

        if (handle = PathUtil.INVALID_HANDLE_VALUE)
            return ""

        try {
            buf := Buffer(PathUtil.SIZE_FILE_INFORMATION, 0)

            success := DllCall("GetFileInformationByHandle"
                , "Ptr", handle
                , "Ptr", buf)

            if (!success)
                return ""

            return {
                volumeSerial: NumGet(buf, PathUtil.OFFSET_VOLUME_SERIAL_NUMBER, "UInt"),
                indexHigh: NumGet(buf, PathUtil.OFFSET_FILE_INDEX_HIGH, "UInt"),
                indexLow: NumGet(buf, PathUtil.OFFSET_FILE_INDEX_LOW, "UInt")
            }
        } finally {
            DllCall("CloseHandle", "Ptr", handle)
        }
    }

    ; ------------------------------------------------------------
    ; _OpenPathHandle
    ; 功能:
    ;   以只读元数据方式打开文件或目录句柄。
    ; 说明:
    ;   使用 FILE_FLAG_BACKUP_SEMANTICS，使目录也可打开。
    ; 返回:
    ;   成功返回有效句柄，失败返回 INVALID_HANDLE_VALUE。
    ; ------------------------------------------------------------
    static _OpenPathHandle(path) {
        return DllCall("CreateFile"
            , "Str", path
            , "UInt", 0
            , "UInt", PathUtil.FILE_SHARE_READ_WRITE_DELETE
            , "Ptr", 0
            , "UInt", PathUtil.OPEN_EXISTING
            , "UInt", PathUtil.FILE_FLAG_BACKUP_SEMANTICS
            , "Ptr", 0
            , "Ptr")
    }
}
