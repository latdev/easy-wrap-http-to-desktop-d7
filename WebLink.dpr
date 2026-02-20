program WebLink;

{$APPTYPE GUI}

uses SysUtils, Windows, Classes, StrUtils,
    IdBaseComponent, IdComponent, IdTCPServer,
    IdCustomHTTPServer, IdHTTPServer, IdURI;

type
    NativeApp = class(TObject)
    private
        WebServer: TIdHTTPServer;
        procedure FilesAllowedToRead(AStrings: TStrings);
        procedure ListFiles(AThread: TIdPeerThread; AReq: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
        function IsFileCanBeReaded(AReq: TIdHTTPRequestInfo): Boolean;
        function SetContTypeByFileName(AFileName: String): String;
        procedure ReadFile(AThread: TIdPeerThread; AReq: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
        function IsFileNameValid(AFileName: AnsiString): Boolean;
        function IsFileCanBeWritten(const AFileName: String): Boolean;
        procedure SaveFile(AThread: TIdPeerThread; AReq: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
        function IsStringUTF8Like(const S: AnsiString): Boolean;
    public
        constructor Create;
        procedure Free;
        function Start: Boolean;
        function LockThread: Integer;
    protected
        procedure OnCommandGet(AThread: TIdPeerThread; AReq: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
        procedure OnCreatePostStream(ASender: TIdPeerThread; var VPostStream: TStream);
    end;

var App: NativeApp;

{ App }

procedure NativeApp.OnCommandGet(AThread: TIdPeerThread; AReq: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
begin
    if (AReq.Command = 'GET') and (AReq.Document = '/') then ListFiles(AThread, AReq, AResp)
    else if AReq.Command = 'GET' then ReadFile(AThread, AReq, AResp)
    else if AReq.Command = 'POST' then SaveFile(AThread, AReq, AResp)
    else AResp.ResponseNo := 405;
end;

procedure NativeApp.FilesAllowedToRead(AStrings: TStrings);
var
    sOwnName: String;
    stSearchRec: TSearchRec;
begin
    sOwnName := ExtractFileName(ParamStr(0));
    if FindFirst(ExtractFilePath(ParamStr(0)) + '*.*', faAnyFile, stSearchRec) = 0 then begin
        repeat
            if stSearchRec.Name[1] = '.' then Continue; // IsUnixHidden
            if (stSearchRec.Attr and faDirectory) <> 0 then Continue; // IsDirectory
            if (stSearchRec.Attr and faHidden) <> 0 then Continue; // IsWindowsHidden
            if (stSearchRec.Attr and faSysFile) <> 0 then Continue; // IsWindowsSystem
            if CompareStr(stSearchRec.Name, sOwnName) = 0 then Continue; // ThisIsMyOwnExe
            // IsGoodFile
            AStrings.Add('/' + TIdURI.ParamsEncode(stSearchRec.Name));
            //  DECODE WITH  ==  Result := TIdURI.URLDecode(AUrl);
        until FindNext(stSearchRec) <> 0;
        SysUtils.FindClose(stSearchRec);
    end;
end;

procedure NativeApp.ListFiles(AThread: TIdPeerThread; AReq: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
var pFiles: TStrings;
begin
    pFiles := TStringList.Create;
    try
        FilesAllowedToRead(pFiles);
        AResp.ContentType := 'text/plain; charset=utf-8';
        AResp.ContentText := UTF8Encode(pFiles.Text);
    finally
        FreeAndNil(pFiles);
    end;
end;

function NativeApp.IsFileCanBeReaded(AReq: TIdHTTPRequestInfo): Boolean;
var
    nRawName: string;
    pReadList: TStrings;
begin
    Result := False;
    pReadList := TStringList.Create;
    try
        FilesAllowedToRead(pReadList);
        nRawName := TIdURI.ParamsEncode(AReq.Document);
        if pReadList.IndexOf(nRawName) > -1 then begin
            Result := True;
        end;
    finally
        FreeAndNil(pReadList);
    end;
end;

function NativeApp.SetContTypeByFileName(AFileName: String): String;
var SExt: String;
begin
    SExt := LowerCase(ExtractFileExt(AFileName));
    if AnsiSameStr(SExt, '.json') then Result := 'application/json; charset=utf-8'
    else if AnsiSameStr(SExt, '.css') then Result := 'text/css; charset=utf-8'
    else if AnsiSameStr(SExt, '.js') then Result := 'application/javascript; charset=utf-8'
    else if AnsiSameStr(SExt, '.html') or AnsiSameStr(SExt, '.htm') then
        Result := 'text/html; charset=utf-8'
    else if AnsiSameStr(SExt, '.txt') then Result := 'text/plain; charset=utf-8'
    else if AnsiSameStr(SExt, '.ico') then Result := 'image/x-icon'
    else if AnsiSameStr(SExt, '.jpg') or AnsiSameStr(SExt, '.jpeg') then Result := 'image/jpeg'
    else if AnsiSameStr(SExt, '.png') then Result := 'image/png'
    else if AnsiSameStr(SExt, '.gif') then Result := 'image/gif'
    else Result := 'application/octet-stream';
end;

procedure NativeApp.ReadFile(AThread: TIdPeerThread; AReq: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
var sFullFilePath: String;
begin
    if not IsFileCanBeReaded(AReq) then begin
        AResp.ResponseNo := 404;
        Exit;
    end;
    sFullFilePath := ExtractFilePath(ParamStr(0)) + AReq.Document;
    if FileExists(sFullFilePath) then begin
        AResp.ContentType := SetContTypeByFileName(AReq.Document);
        WebServer.ServeFile(AThread, AResp, sFullFilePath);
    end else begin
        AResp.ResponseNo := 404;
    end;
end;

function NativeApp.IsFileNameValid(AFileName: AnsiString): Boolean;
const ValidChars: set of AnsiChar = [
    'A'..'Z', 'a'..'z',
    #$C0..#$DF, // 'AA'..'JA' (CP-1251)
    #$E0..#$FF, // 'aa'..'ja' (CP-1251)
    #$A8, #$B8, // 'JO' , 'jo' (CP-1251)
    '0'..'9',
    '_', '-', '.', '+', ' ' ];
var I: Integer;
begin
    Result := False;
    if Length(AFileName) <= 1 then Exit;
    for I := 2 to Length(AFileName) do begin
        if not (AFileName[i] in ValidChars) then Exit;
    end;
    Result := True;
end;

function NativeApp.IsFileCanBeWritten(const AFileName: String): Boolean;
var sFileName: String;
    sPathName: String;
    dwAttr: DWORD;
begin
    Result := False;
    if not IsFileNameValid(AFileName) then Exit;
    sFileName := ExtractFileName(AFileName);
    if sFileName[1] = '.' then Exit; // IsUnixHidden
    sPathName := ExtractFilePath(ParamStr(0)) + '\' + sFileName;
    if FileExists(sPathName) then begin
        dwAttr := GetFileAttributes(PChar(sPathName));
        if (dwAttr and faDirectory) <> 0 then Exit; // IsDirectory
        if (dwAttr and faHidden) <> 0 then Exit; // IsWindowsHidden
        if (dwAttr and faSysFile) <> 0 then Exit; // IsWindowsSystem
        if (dwAttr and faReadOnly) <> 0 then Exit; // READ ONLY FILE, NOT WRITEABLE!!!
        if (dwAttr and faSymLink) <> 0 then Exit; // LINK TO FILE, NOT REAL FILE!!!
        if CompareStr(sFileName, ExtractFileName(ParamStr(0))) = 0 then Exit; // ThisIsMyOwnExe
    end;
    Result := True;
end;

procedure NativeApp.SaveFile(AThread: TIdPeerThread; AReq: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
var
    sFileName: String;
    nBytesToWriteOnDisk: Int64;
begin
    if IsStringUTF8Like(AReq.Document) then begin
        AReq.Document := UTF8Decode(AReq.Document);
    end;
    // TODO -oEugeneX: IdURL пропускает '+' не как пробел, а как '+' тут обсосать это дело
    if not IsFileCanBeWritten( AReq.Document) then begin // <--- Я должет тут ебануть UTF8Decode
        AResp.ResponseNo := 400;
        AResp.ResponseText := 'Bad Request';
        Exit;
    end;
    // V--- И тут тоже?
    sFileName := ExtractFilePath(ParamStr(0)) + '\' + ExtractFileName(AReq.Document);

    try
        nBytesToWriteOnDisk := AReq.PostStream.Seek(0, soFromEnd);
        AReq.PostStream.Seek(0, soFromBeginning);
        with TFileStream.Create(sFileName, fmCreate) do
        try
            CopyFrom(AReq.PostStream, nBytesToWriteOnDisk);
        finally
            Free;
        end;
        AResp.ContentType := 'text/plain; charset=utf-8';
        AResp.ResponseText := 'OK';
    except on Err: Exception do begin
        AResp.ResponseNo := 500;
        AResp.ContentText := Err.ClassName + ': ' + Err.Message;
    end end;
end;

function NativeApp.IsStringUTF8Like(const S: AnsiString): Boolean;
var
    I: Integer;
    L: Integer;
begin
    Result := False;
    L := Length(S);
    if L = 0 then Exit;

    for I := 1 to L - 1 do begin
        // Проверяем характерные маркеры кириллицы UTF-8:
        // Первый байт $D0 или $D1, второй байт от $80 до $BF
        if (S[I] in [#$D0, #$D1]) and (S[I+1] in [#$80..#$BF]) then begin
            Result := True;
            Exit;
        end;
    end;
end;

procedure NativeApp.OnCreatePostStream(ASender: TIdPeerThread; var VPostStream: TStream);
begin
    VPostStream := TMemoryStream.Create;
end;

function NativeApp.Start: Boolean;
begin
    try
        WebServer.Active := True;
    finally
        Result := WebServer.Active;
    end;
end;

function NativeApp.LockThread: Integer;
var lpMsg: tagMSG;
begin
    while GetMessage(lpMsg, 0, 0, 0) do begin
        TranslateMessage(lpMsg);
        DispatchMessage(lpMsg);
    end;
    Result := lpMsg.wParam;
end;

constructor NativeApp.Create;
begin
    WebServer := TIdHTTPServer.Create(nil);
    WebServer.DefaultPort := 50086;
    WebServer.Bindings.Clear;
    with WebServer.Bindings.Add do begin
        IP := '127.0.0.1';
        Port := WebServer.DefaultPort;
    end;
    WebServer.ServerSoftware := 'XWebLink/1.0';
    WebServer.OnCommandGet := OnCommandGet;
    WebServer.OnCreatePostStream := OnCreatePostStream;
end;

procedure NativeApp.Free;
begin
    FreeAndNil(WebServer);
end;

{ Bootloader }

begin
    App := NativeApp.Create;
    try
        ExitCode := 1;
        if App.Start then begin
            ExitCode := App.LockThread
        end;
    finally
        FreeAndNil(App);
    end;
end.
