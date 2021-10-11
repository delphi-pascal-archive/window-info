////////////////////////////////////////////////////////////////////////////////
//
//  ****************************************************************************
//  * Unit Name : wndinfo32
//  * Purpose   : Утилита для отображения краткой информации по окну под курсором.
//  * Author    : Александр (Rouse_) Багель
//  * Copyright : © Fangorn Wizards Lab 1998 - 2007
//  * Home Page : http://rouse.drkb.ru
//  * Version   : 1.00
//  ****************************************************************************
//
//
//  ****************************************************************************
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//  ****************************************************************************


program wndinfo32;
                      
{$R 'wndinfo32.res' 'wndinfo32.rc'}

uses
  Windows,
  Messages,
  CommCtrl,
  ShellAPI;

resourcestring
  ClassName = 'wndinfo32';
  AutoRunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  NTFSThread = ':Settings'#0;
  TrayHint = 'wndinfo32';
  HintCopyright = 'WndInfo32 © Alexander (Rouse_) Bagel';

type
  TMouseMoveHook = record
    case Integer of
    0: (Hook: HHOOK);
    1: (Timer: THandle);
  end;

  PMsLLHookStruct = ^TMsLLHookStruct;
  tagMSLLHOOKSTRUCT = packed record
    pt: TPoint;
    mouseData: DWORD;
    flags: DWORD;
    time: DWORD;
    dwExtraInfo: PDWORD;
  end;
  TMsLLHookStruct = tagMSLLHOOKSTRUCT;

  THintPos = (hpTopLeft, hpTopRight, hpBottomLeft, hpBottomRight);

  TWindowInfo = record
    szClassName: array [0..MAXCHAR - 1] of Char;
    szCaption: array [0..MAXCHAR - 1] of Char;
    Left, Top, Width, Height: Integer;
    dwThreadID, dwProcessID, dwHandle, dwControlID: DWORD;
    szLayoutName: array [0..MAXCHAR - 1] of Char;
    hIcon: HICON;
  end;

var
  WndClassEx: TWndClassEx;
  WndClassAtom: ATOM;
  MainWindowHandle: HWND;
  PopupMenu: HWND;
  SettingPath, HintCaption, AdvancedHintInfo: String;
  SettingModify, SettingKey: Byte;
  IconData: TNotifyIconData;
  AppEnabled: Boolean = False;
  WM_TASKBARCREATED: Integer = 0;
  MouseMoveHook: TMouseMoveHook;
  WndWidth, WndHeight, CaptionWidth, CaptionHeight, AdvOffset: Integer;
  WndInfo: TWindowInfo;
  hFontHandle, hFontBoldHandle: HFONT;

const
  ICO_ENABLE  = 100;
  ICO_DISABLE = 101;

//  Транслируем код горячей клавиши из представления,
//  необходимого классу msctls_hotkey32 в вид,
//  пригодный для вызова RegisterHotkey
// =============================================================================
function TranslateHotkeyToMod(const Value: Byte): Byte;
begin
  Result := 0;
  if (Value and HOTKEYF_SHIFT) = HOTKEYF_SHIFT then
    Result := Result or MOD_SHIFT;
  if (Value and HOTKEYF_CONTROL) = HOTKEYF_CONTROL then
    Result := Result or MOD_CONTROL;
  if (Value and HOTKEYF_ALT) = HOTKEYF_ALT then
    Result := Result or MOD_ALT;
  if (Value and HOTKEYF_EXT) = HOTKEYF_EXT then
    Result := Result or MOD_WIN;
end;

//  Регистрация горячей клавиши
// =============================================================================
function RegisterHotkeys: Boolean;
begin
  Result :=
    RegisterHotkey(MainWindowHandle, WndClassAtom,
      TranslateHotkeyToMod(SettingModify), SettingKey);
end;

//  Снятие горячей клавиши с регистрации
// =============================================================================
procedure UnRegisterHotkeys;
begin
  UnRegisterHotkey(MainWindowHandle, WndClassAtom);
end;

//  Снятие оконного класса приложения с регистрации
// =============================================================================
procedure UnRegisterWnd;
begin
  UnregisterClass(PChar(ClassName), HInstance);
end;

//  Цикл выборки сообщений
// =============================================================================
procedure MainLoop;
var
  Msg: TMsg;
begin
  while GetMessage(Msg, 0, 0, 0) do
  begin
    TranslateMessage(Msg);
    DispatchMessage(Msg);
  end;
end;

//  Проверка версии операционной системы.
//  Функция возвращает положительный результат в случае Windows >= 2000
// =============================================================================
function IsValidNTVersion: Boolean;
var
  OSVersionInfo: TOSVersionInfo;
begin
  Result := False;
  ZeroMemory(@OSVersionInfo, SizeOf(TOSVersionInfo));
  OSVersionInfo.dwOSVersionInfoSize := SizeOf(TOSVersionInfo);
  if GetVersionEx(OSVersionInfo) then
    if OSVersionInfo.dwPlatformId = VER_PLATFORM_WIN32_NT then
      Result := OSVersionInfo.dwMajorVersion > 4;
end;

//  Проверка, расположенна ли программа в разделе с файловой системой NTFS
// =============================================================================
function UseNtfsThreadForSettingPath: Boolean;
var
  Root: String[4];
  Flag, Len: Cardinal;
  FS: array [0..24] of Char;
begin
  Result := False;
  if IsValidNTVersion then
  begin
    lstrcpyn(@Root[1], PChar(ParamStr(0)), 4);
    if GetVolumeInformation(PChar(@Root[1]), nil, 0,
      nil, Len, Flag, @FS, 25) then
      Result := String(FS) = 'NTFS';
  end;
end;

//  Функция инициализирует переменную, содержащую путь к настройкам приложения
// =============================================================================
procedure InitSettingPath;
var
  SettLength: Integer;
begin
  SettingPath := ParamStr(0);
  if UseNtfsThreadForSettingPath then
    SettingPath := SettingPath + NTFSThread
  else
  begin
    SettLength := Length(SettingPath);
    SettingPath[SettLength - 2] := 'd';
    SettingPath[SettLength - 1] := 'a';
    SettingPath[SettLength] := 't';
  end;
end;

//  Загрузка настроек приложения
// =============================================================================
procedure LoadSettings;
var
  fHandle: THandle;
  Size, ReadSize: DWORD;
begin
  SettingModify := Byte(-1);
  SettingKey := Byte(-1);
  try
    fHandle := CreateFile(PChar(SettingPath), GENERIC_READ,
      0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if fHandle <> INVALID_HANDLE_VALUE then
    try
      Size := GetFileSize(fHandle, nil);
      if Size = 2 then
      begin
        if ReadFile(fHandle, SettingModify, 1, ReadSize, nil) then
          ReadFile(fHandle, SettingKey, 1, ReadSize, nil);
      end;
    finally
      CloseHandle(fHandle);
    end;
  finally
    // Если не смогли загрузить - настройки выставляются по умолчанию
    if (SettingModify = Byte(-1)) or (SettingKey = Byte(-1))  then
    begin
      SettingModify := HOTKEYF_CONTROL;
      SettingKey := VK_F12;
    end;
  end;
end;

//  Сохранение настроек приложения
// =============================================================================
procedure SaveSettings;
var
  fHandle: THandle;
  WriteSize: DWORD;
begin
  fHandle := CreateFile(PChar(SettingPath), GENERIC_WRITE,
    0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if fHandle > 0 then
  try
    if WriteFile(fHandle, SettingModify, 1, WriteSize, nil) then
      WriteFile(fHandle, SettingKey, 1, WriteSize, nil);
  finally
    CloseHandle(fHandle);
  end;
end;

//  Проверка, содержится ли в разделе реестра,
//  отвечающего за автозапуск, запись о приложении
// =============================================================================
function IsAutoRun: Boolean;
var
  Key: HKEY;
  Size, dwType: DWORD;
  Buff: String;
begin
  Result := False;
  if RegOpenKeyEx(HKEY_CURRENT_USER,
    PChar(AutoRunKey),
    0, KEY_READ, Key) = ERROR_SUCCESS then
  try
    if RegQueryValueEx(Key, PChar(ClassName), nil, @dwType,
      nil, @Size) <> ERROR_SUCCESS then Exit;
    if (dwType in [REG_SZ, REG_EXPAND_SZ]) and (Size > 0) then
    begin
      SetLength(Buff, Size);
      if RegQueryValueEx(Key, PChar(ClassName), nil, @dwType,
        PByte(PChar(Buff)), @Size) <> ERROR_SUCCESS then Exit;
      Result :=
        lstrcmp(CharLower(PChar(Buff)), CharLower(PChar(ParamStr(0)))) = 0;
    end;
  finally
    RegCloseKey(Key);
  end;
end;

//  Функция прописывает приложение в автозагрузку и снимает с нее
// =============================================================================
function SetAutoRun(NeedAutoRun: Boolean): Boolean;
var
  Key: HKEY;
  Buff: String;
begin
  Result := False;
  if RegOpenKeyEx(HKEY_CURRENT_USER,
    PChar(AutoRunKey),
    0, KEY_WRITE, Key) = ERROR_SUCCESS then
  try
    if NeedAutoRun then
    begin
      Buff := ParamStr(0);
      Result := RegSetValueEx(Key, PChar(ClassName), 0,
        REG_SZ, @Buff[1], Length(Buff)) = ERROR_SUCCESS;
    end
    else
      Result := RegDeleteValue(Key, PChar(ClassName)) = ERROR_SUCCESS;
  finally
    RegCloseKey(Key);
  end;
end;

//  Диалоговая функция для окна настроек
// =============================================================================
function DlgFunc(hwndDlg: HWND; Msg: UINT;
  WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
const
  IDC_HOTKEY = 1001;
  IDC_CHECK  = 1002;
var
  ScrWidth, ScrHeight, AHotKey: Cardinal;
  Left, Top, Width, Height: Integer;
  ARect: TRect;
begin
  case Msg of
    WM_INITDIALOG:
    begin
      GetWindowRect(hwndDlg, ARect);
      Width := ARect.Right;
      Height := ARect.Bottom;
      ScrWidth := GetSystemMetrics(SM_CXSCREEN);
      ScrHeight := GetSystemMetrics(SM_CYSCREEN);
      Left := (Integer(ScrWidth) - Width) div 2;
      Top := (Integer(ScrHeight) - Height) div 2;
      SetWindowPos(hwndDlg, GW_HWNDFIRST, Left, Top, 0, 0, SWP_NOSIZE);
      CheckDlgButton(hwndDlg, IDC_CHECK, DWORD(IsAutoRun));
      SendMessage(GetDlgItem(hwndDlg, IDC_HOTKEY), HKM_SETHOTKEY,
        MAKEWORD(SettingKey, SettingModify), 0);
      SetFocus(GetDlgItem(hwndDlg, IDC_HOTKEY));
    end;
    WM_COMMAND:
      case LoWord(WParam) of
        IDOK:
        begin
          AHotKey := SendMessage(GetDlgItem(hwndDlg, IDC_HOTKEY),
            HKM_GETHOTKEY, 0, 0);
          SettingKey := Byte(AHotKey);
          SettingModify := Byte(AHotKey shr 8);
          SaveSettings;
          EndDialog(hwndDlg, 1);
        end;
        IDCANCEL:
          EndDialog(hwndDlg, 0);
        IDC_CHECK:
          CheckDlgButton(hwndDlg, IDC_CHECK, DWORD(
            SetAutoRun(IsDlgButtonChecked(hwndDlg, IDC_CHECK) = BST_CHECKED)));
      end;
  end;
  Result := 0;
  SetWindowLong(hwndDlg, DWL_MSGRESULT, Result);
end;

//  Функция создает диалог с настройками.
//  Возвращает положительное значение если была нажата кнопка "Применить"
// =============================================================================
function ShowSettingDialog: Boolean;
const
  IDD_DIALOG = 1000;
begin
  Result := Boolean(DialogBox(HInstance, MAKEINTRESOURCE(IDD_DIALOG),
    0, @DlgFunc));
end;

//  Процедура добавляет иконку в системный трей
// =============================================================================
procedure AddTrayIcon;
begin
  WM_TASKBARCREATED := RegisterWindowMessage('TaskbarCreated');
  ZeroMemory(@IconData, SizeOf(TNotifyIconData));
  IconData.cbSize := SizeOf(TNotifyIconData);
  IconData.Wnd := MainWindowHandle;
  IconData.uFlags := NIF_ICON or NIF_TIP or NIF_MESSAGE;
  IconData.uCallbackMessage := WM_USER;
  IconData.hIcon := LoadIcon(HInstance, MAKEINTRESOURCE(ICO_DISABLE));
  Move(TrayHint[1], IconData.szTip[0], Length(TrayHint));
  Shell_NotifyIcon(NIM_ADD, @IconData);
end;

//  Процедура удаляет иконку из системного трея
// =============================================================================
procedure DelTrayIcon;
begin
  Shell_NotifyIcon(NIM_DELETE, @IconData);
  DestroyIcon(IconData.hIcon);
end;

//  Процедура получает данные о окне под курсором,
//  рассчитывает размеры окна, необходимого для отображения информации
//  выставляет необходимые размеры и позиционирует окно относительно курсора
// =============================================================================
procedure ShowWindowInfoAtPos(PT: TPoint);

  // функция рассчитывает в какой части экрана находится курсор
  function GetHintPos: THintPos;
  var
    AResult: Byte;
  begin
    AResult := 0;
    Inc(AResult, Byte(PT.X > GetSystemMetrics(SM_CXSCREEN) div 2));
    Inc(AResult, Byte(PT.Y > GetSystemMetrics(SM_CYSCREEN) div 2) * 2);
    Result := THintPos(AResult);
  end;

  // Процедура получаия информации по окну,
  // расположенному по координатам курсора
  procedure GetInfo;
  var
    AHandle: DWORD;
    ARect: TRect;
  begin
    AHandle := WindowFromPoint(PT);
    if AHandle = WndInfo.dwHandle then Exit;
    ZeroMemory(@WndInfo, SizeOf(TWindowInfo));
    WndInfo.dwHandle := AHandle;
    GetClassName(AHandle, WndInfo.szClassName, MAXCHAR);
    GetWindowText(AHandle, WndInfo.szCaption, MAXCHAR);
    WndInfo.dwThreadID :=
      GetWindowThreadProcessId(AHandle, WndInfo.dwProcessID);
    AttachThreadInput(GetCurrentThreadId, WndInfo.dwThreadID, True);
    VerLanguageName(GetKeyboardLayout(WndInfo.dwThreadID) and $FFFF,
      WndInfo.szLayoutName, MAXCHAR);
    AttachThreadInput(GetCurrentThreadId, WndInfo.dwThreadID, False);
    GetWindowRect(AHandle, ARect);
    WndInfo.Left := ARect.Left;
    WndInfo.Top := ARect.Top;
    WndInfo.Width := ARect.Right - ARect.Left;
    WndInfo.Height := ARect.Bottom - ARect.Top;
    WndInfo.dwControlID := GetDlgCtrlID(AHandle);
    WndInfo.hIcon := GetClassLong(AHandle, GCL_HICON);
    InvalidateRect(MainWindowHandle, nil, True);
  end;

  // Процедура рассчета размеров окна, на основании размера данных
  procedure CalcHintSize;
  var
    Mask1, Mask2, AClassName, ACaption, LayoutName: String;
    DC, OldDC: HDC;
    Rect: TRect;
    TotalHeight, MaxWidth: Integer;

    procedure EmptyRect;
    begin
      ZeroMemory(@Rect, SizeOf(TRect));
      Rect.Bottom := 1;
      Rect.Right := 300;
    end;

  begin
    SetLength(HintCaption, 255);
    SetLength(AdvancedHintInfo, 255);
    AClassName := String(WndInfo.szClassName);
    ACaption := String(WndInfo.szCaption);
    LayoutName := String(WndInfo.szLayoutName);
    Mask1 := 'ClassName: %s'#13#10'Left: %d'#13#10'Top: %d'#13#10 +
      'Width: %d'#13#10'Height: %d';
    Mask2 := 'Caption: %s'#13#10'LayoutName: %s'#13#10 +
      'ThreadID: %d'#13#10 +
      'ProcessID: %d'#13#10'Handle: %d'#13#10'ControlID: %d';
    asm
      push WndInfo.Height
      push WndInfo.Width
      push WndInfo.Top
      push WndInfo.Left
      push PChar(AClassName)
      push PChar(Mask1)
      push PChar(HintCaption)
      call wsprintf
      add esp, 28
      push WndInfo.dwControlID
      push WndInfo.dwHandle
      push WndInfo.dwProcessID
      push WndInfo.dwThreadID
      push PChar(LayoutName)
      push PChar(ACaption)
      push PChar(Mask2)
      push PChar(AdvancedHintInfo)
      call wsprintf
      add esp, 32
    end;

    DC := GetDC(MainWindowHandle);
    try

      OldDC := SelectObject(DC, hFontBoldHandle);
      try
        EmptyRect;
        DrawText(DC, PChar(HintCopyright), Length(PChar(HintCopyright)),
          Rect, DT_SINGLELINE or DT_CALCRECT);
        TotalHeight := Rect.Bottom + 4;
        CaptionHeight := TotalHeight;
        CaptionWidth := Rect.Right;
        MaxWidth := CaptionWidth + 4;
      finally
        SelectObject(DC, OldDc);
      end;

      OldDC := SelectObject(DC, hFontHandle);
      try
        EmptyRect;
        DrawText(DC, PChar(HintCaption), Length(PChar(HintCaption)),
          Rect, DT_WORDBREAK or DT_CALCRECT);
        Inc(TotalHeight, Rect.Bottom + 4);
        if MaxWidth < Rect.Right then
          MaxWidth := Rect.Right;

        AdvOffset := TotalHeight + 8;

        EmptyRect;
        DrawText(DC, PChar(AdvancedHintInfo), Length(PChar(AdvancedHintInfo)),
          Rect, DT_WORDBREAK or DT_CALCRECT);
        Inc(TotalHeight, Rect.Bottom + 4);
        if MaxWidth < Rect.Right then
          MaxWidth := Rect.Right;
      finally
        SelectObject(DC, OldDc);
      end;
      
    finally
      ReleaseDC(MainWindowHandle, DC);
    end;
    WndWidth := MaxWidth + 20;
    WndHeight := TotalHeight + 10;
    if WndInfo.hIcon <> 0 then
      Inc(WndWidth, 32);
  end;

var
  CursorWidth, CursorHeight: Integer;
begin
  // Получаем информацию по окну
  GetInfo;
  // Рассчитываем размеры окна
  CalcHintSize;
  CursorWidth := GetSystemMetrics(SM_CXCURSOR);
  CursorHeight := GetSystemMetrics(SM_CYCURSOR);
  // Рассчитываем смещение окна относительно положения курсора
  case GetHintPos of
    hpTopLeft:
    begin
      Inc(PT.X, CursorWidth);
      Inc(PT.Y, CursorHeight);
    end;
    hpTopRight:
    begin
      Dec(PT.X, CursorWidth + WndWidth);
      Inc(PT.Y, CursorHeight);
    end;
    hpBottomLeft:
    begin
      Inc(PT.X, CursorWidth);
      Dec(PT.Y, CursorHeight + WndHeight);
    end;
    hpBottomRight:
    begin
      Dec(PT.X, CursorWidth + WndWidth);
      Dec(PT.Y, CursorHeight + WndHeight);
    end;
  end;
  // Перемещаем окно и правим его размеры
  SetWindowPos(MainWindowHandle, HWND_TOPMOST,
    PT.X, PT.Y, WndWidth, WndHeight, SWP_NOACTIVATE);
end;

//  Функция для низкоуровневой ловушки сообщений мышки
//  Используется в случае если ОС >= Windows 2000
// =============================================================================
function LowLevelMouseProc(nCode: Integer;
  WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;

  function Point(const X, Y: Word):  TPoint;
  begin
    Result.X := X;
    Result.Y := Y;
  end;

begin
  Result := CallNextHookEx(MouseMoveHook.Hook, nCode, WParam, LParam);
  if WParam = WM_MOUSEMOVE then
    ShowWindowInfoAtPos(Point(
      PMsLLHookStruct(LParam)^.pt.X,
      PMsLLHookStruct(LParam)^.pt.Y));
end;

//  Функция обрабатывающая сообщения системного таймера
//  Используется при невозможности установить низкоуровневую ловушку
// =============================================================================
procedure TimerProc(Window: HWnd; Message: Cardinal;
  wParam: WPARAM; lParam: LPARAM); stdcall;
var
  Pt: TPoint;
begin
  GetCursorPos(Pt);
  ShowWindowInfoAtPos(Pt);
end;

//  Процедура изменяет иконку в системном трее
// =============================================================================
procedure ModifyTrayIcon(const IsEnabled: Boolean);
var
  MenuItemInfo: TMenuItemInfo;
  Pt: TPoint;
begin
  ZeroMemory(@MenuItemInfo, SizeOf(TMenuItemInfo));
  MenuItemInfo.cbSize := SizeOf(TMenuItemInfo);
  MenuItemInfo.fMask := MIIM_STATE;
  GetMenuItemInfo(GetSubMenu(PopupMenu, 0), 0, True, MenuItemInfo);
  MenuItemInfo.fState := (MenuItemInfo.fState and not MFS_CHECKED)
    or MFS_CHECKED * Byte(IsEnabled);
  SetMenuItemInfo(GetSubMenu(PopupMenu, 0), 0, True, MenuItemInfo);
  DestroyIcon(IconData.hIcon);
  if IsEnabled then
     IconData.hIcon := LoadIcon(HInstance, MAKEINTRESOURCE(ICO_ENABLE))
  else
    IconData.hIcon := LoadIcon(HInstance, MAKEINTRESOURCE(ICO_DISABLE));
  Shell_NotifyIcon(NIM_MODIFY, @IconData);
  GetCursorPos(Pt);
  ShowWindowInfoAtPos(Pt);
  ShowWindow(MainWindowHandle, Integer(IsEnabled));
end;

//  Активация наблюдения за мышкой
// =============================================================================
procedure SetMouseHook(const IsEnabled: Boolean);
const
  WH_MOUSE_LL = 14;
begin
  if IsEnabled then
  begin
    if IsValidNTVersion then
      MouseMoveHook.Hook :=
        SetWindowsHookEx(WH_MOUSE_LL, @LowLevelMouseProc, HInstance, 0)
    else
      MouseMoveHook.Timer := SetTimer(0, 0, 10, @TimerProc);
  end
  else
  begin
    if IsValidNTVersion then
      UnhookWindowsHookEx(MouseMoveHook.Hook)
    else
      KillTimer(0, MouseMoveHook.Timer);
  end;
end;

//  Оконная процедура главного окна приложения
// =============================================================================
function WindowProc(Wnd: HWND; Msg: Integer;
  WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
const
  ID_MAIN_ENABLE  = 2001;
  ID_MAIN_SETTING = 2002;
  ID_MAIN_EXIT    = 2003;
var
  pt: TPoint;
  PopupMenuResult: BOOL;
  OldDC: HDC;
  Rect: TRect;
  lpPaint: TPaintStruct;
begin
  case Msg of

    // Реагируем на горячую клавишу
    WM_HOTKEY:
    begin
      AppEnabled := not AppEnabled;
      ModifyTrayIcon(AppEnabled);
      SetMouseHook(AppEnabled);
    end;

    // Реагируем на сообщения из трея
    WM_USER:
      case LParam of

        // Если щелкнули правой мышкой - отображаем меню
        WM_RBUTTONUP:
        begin
          GetCursorPos(pt);
          SetForegroundWindow(Wnd);
          PopupMenuResult := TrackPopupMenu(GetSubMenu(PopupMenu, 0),
            TPM_LEFTALIGN or TPM_LEFTBUTTON or TPM_RETURNCMD,
            pt.X, pt.Y, 0, MainWindowHandle, nil);
          PostMessage(Wnd, WM_NULL, 0, 0);
          // Обрабатываем действия по выбранным пунктам меню
          case LongInt(PopupMenuResult) of

            ID_MAIN_ENABLE:
              PostMessage(Wnd, WM_HOTKEY, 0, 0);

            ID_MAIN_SETTING:
              if ShowSettingDialog then
              begin
                UnRegisterHotkeys;
                RegisterHotkeys;
              end;

            ID_MAIN_EXIT:
              PostQuitMessage(0);
          end;
        end;

        // по даойному клику - отображаем диалог настроек
        WM_LBUTTONDBLCLK:
          if ShowSettingDialog then
          begin
            UnRegisterHotkeys;
            RegisterHotkeys;
          end;
      end;

    WM_NCHITTEST:
    begin
      Result := HTTRANSPARENT;
      Exit;
    end;

    // Отрисовка окна на основе собранной ранее информации
    WM_PAINT:
    begin
      BeginPaint(Wnd, lpPaint);
      try
        Rect.Left := 0;
        Rect.Top := 0;
        Rect.Right := WndWidth;
        Rect.Bottom := WndHeight;
        lpPaint.rcPaint := Rect;

        OldDC := SelectObject(lpPaint.hdc, GetStockObject(DC_BRUSH));
        try
          SetDCBrushColor(lpPaint.hdc, $80FFFF);
          FillRect(lpPaint.hdc, Rect, 0);
          SetDCBrushColor(lpPaint.hdc, RGB(38, 98, 223));
          Rect.Bottom := CaptionHeight;
          FillRect(lpPaint.hdc, Rect, 0);
          Rect.Bottom := WndHeight;
        finally
          SelectObject(lpPaint.hdc, OldDc);
        end;

        DrawIcon(lpPaint.hdc, 3, CaptionHeight + 2, WndInfo.hIcon);

        OldDC := SelectObject(lpPaint.hdc, hFontBoldHandle);
        try
          SetBkMode(lpPaint.hdc, TRANSPARENT);
          SetTextColor(lpPaint.hdc, $FFFFFF);
          try
            TextOut(lpPaint.hdc,
              (Rect.Right - CaptionWidth) div 2, 2, PChar(HintCopyright),
              Length(PChar(HintCopyright)));
          finally
            SetTextColor(lpPaint.hdc, 0);
          end;                
        finally
          SelectObject(lpPaint.hdc, OldDc);
        end;

        OldDC := SelectObject(lpPaint.hdc, hFontHandle);
        try
          Inc(Rect.Left, 4 + (Byte(WndInfo.hIcon <> 0) * 34));
          Inc(Rect.Top, 2 + CaptionHeight);
          DrawText(lpPaint.hdc, PChar(HintCaption),
            Length(PChar(HintCaption)),
            Rect, DT_WORDBREAK);

          Dec(Rect.Left, (Byte(WndInfo.hIcon <> 0) * 34));
          Rect.Top := AdvOffset;
          DrawText(lpPaint.hdc, PChar(AdvancedHintInfo),
            Length(PChar(AdvancedHintInfo)),
            Rect, DT_WORDBREAK);
        finally
          SelectObject(lpPaint.hdc, OldDc);
        end;

      finally
        EndPaint(Wnd, lpPaint);
      end;
      Result := 0;
      Exit;
    end

  else
    // Если пришло сообщение о пересоздании таскбара -
    // помещаем иконку обратно в трей
    if Msg = WM_TASKBARCREATED then
    begin
      DelTrayIcon;
      AddTrayIcon;
    end;
  end;
  Result := DefWindowProc(Wnd, Msg, wParam, lParam);
end;

//  Регистрация главного оконного класса приложения
// =============================================================================
function RegisterWnd: Boolean;
begin
  with WndClassEx do
  begin
    cbSize := SizeOf(TWndClassEx);
    style := CS_HREDRAW or CS_VREDRAW or CS_SAVEBITS;
    lpfnWndProc := @WindowProc;
    cbClsExtra := 0;
    cbWndExtra := 0;
    hIcon := LoadIcon(0, IDI_APPLICATION);
    hCursor  := LoadCursor(0, IDC_ARROW);
    hbrBackground := COLOR_BTNFACE + 1;
    lpszMenuName := nil;
    lpszClassName := PChar(ClassName);
  end;
  WndClassEx.hInstance := HInstance;
  WndClassAtom := RegisterClassEx(WndClassEx);
  Result := WndClassAtom <> 0;
end;

//  Загрузка и инициализация меню из ресурсов
// =============================================================================
procedure InitMenu;
const
  IDR_MENU = 2000;
var
  MenuItemInfo: TMenuItemInfo;
begin
  PopupMenu := LoadMenu(HInstance, MAKEINTRESOURCE(IDR_MENU));
  ZeroMemory(@MenuItemInfo, SizeOf(TMenuItemInfo));
  MenuItemInfo.cbSize := SizeOf(TMenuItemInfo);
  MenuItemInfo.fMask := MIIM_STATE;
  GetMenuItemInfo(GetSubMenu(PopupMenu, 0), 1, True, MenuItemInfo);
  MenuItemInfo.fState := MenuItemInfo.fState or MFS_DEFAULT;
  SetMenuItemInfo(GetSubMenu(PopupMenu, 0), 1, True, MenuItemInfo);
end;

//  Инициализация и деинициализация приложения
// =============================================================================
var
  StopLoop: Boolean = False;
begin
  InitCommonControls;
  ZeroMemory(@WndInfo, SizeOf(TWindowInfo));
  if RegisterWnd then
  try
    MainWindowHandle := CreateWindowEx(WS_EX_TOOLWINDOW,
      PChar(ClassName), nil, WS_POPUP or WS_BORDER,
      0, 0, 100, 100, 0, 0, HInstance, nil);
    if MainWindowHandle > HINSTANCE_ERROR then
    try
      InitSettingPath;
      while not StopLoop do
      begin
        LoadSettings;
        StopLoop := RegisterHotkeys;
        if not StopLoop then
          if not ShowSettingDialog then Exit;
      end;
      try
        AddTrayIcon;
        try
          InitMenu;
          try
            hFontHandle := CreateFont(-11, 0, 0, 0, FW_NORMAL, 0, 0, 0,
              DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
              DEFAULT_QUALITY, DEFAULT_PITCH or FF_DONTCARE, 'MS Sans Serif');
            try
              hFontBoldHandle := CreateFont(-11, 0, 0, 0, FW_BOLD, 0, 0, 0,
                DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                DEFAULT_QUALITY, DEFAULT_PITCH or FF_DONTCARE, 'MS Sans Serif');
              try
                MainLoop;
              finally
                DeleteObject(hFontBoldHandle);
              end;
            finally
              DeleteObject(hFontHandle);
            end;
          finally
            DestroyMenu(PopupMenu);
          end;
        finally
          SetMouseHook(False);
          DelTrayIcon;
        end;
      finally
        UnRegisterHotkeys;
      end;
    finally
      DestroyWindow(MainWindowHandle);
    end;
  finally
    UnRegisterWnd;
  end;
end.

