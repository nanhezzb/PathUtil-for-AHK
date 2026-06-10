# PathUtil-for-AHK
AutoHotkey v2 Windows 路径同一性比较与规范化工具库。

示例:
比较两个文件路径是否一致
```
result := PathUtil.Equal("C:\PROGRA~1", "%ProgramFiles%")
```
Windows 路径规范化处理
```
result := PathUtil.Normalize("C:\PROGRA~1")
```
