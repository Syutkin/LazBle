unit LazBleGattProfile;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleGattSession;

type
  TLazBleGattProfileState = (
    lbgpsDetached,
    lbgpsAttaching,
    lbgpsReady,
    lbgpsError
  );

  TLazBleGattProfileStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleGattProfileState) of object;
  TLazBleGattProfileStateChangedEvents = array of
    TLazBleGattProfileStateChangedEvent;

  TBleGattProfile = class abstract
  private
    FLock: TRTLCriticalSection;
    FCallbackLock: TRTLCriticalSection;
    FSession: TBleGattSession;
    FState: TLazBleGattProfileState;
    FErrorCode: Integer;
    FErrorMessage: string;
    FAttachedGeneration: QWord;
    FOnStateChanged: TLazBleGattProfileStateChangedEvent;
    FStateChangedHandlers: TLazBleGattProfileStateChangedEvents;
    function GetDeviceId: string;
    function GetState: TLazBleGattProfileState;
    function GetReady: Boolean;
    function GetBound: Boolean;
    function GetCurrentState: TLazBleGattProfileState;
    function GetAttachedGeneration: QWord;
    function GetErrorMessage: string;
    function GetErrorCode: Integer;
    function GetOnStateChanged: TLazBleGattProfileStateChangedEvent;
    procedure SetOnStateChanged(
      const AHandler: TLazBleGattProfileStateChangedEvent);
    procedure SetState(const AState: TLazBleGattProfileState);
  protected
    procedure BindSession(const ASession: TBleGattSession);
    procedure DoBind; virtual;
    procedure DoAttach; virtual; abstract;
    procedure DoDetach; virtual; abstract;
    procedure RefreshState; virtual;
    procedure MarkReady;
    procedure MarkError(const AMessage: string;
      const AErrorCode: Integer = LazBleErrorInvalidState);
    procedure Attach;
    procedure Detach;
    procedure AddStateChangedHandler(
      const AHandler: TLazBleGattProfileStateChangedEvent);
    procedure RemoveStateChangedHandler(
      const AHandler: TLazBleGattProfileStateChangedEvent);
    property CurrentState: TLazBleGattProfileState read GetCurrentState;
    property Session: TBleGattSession read FSession;
    property Bound: Boolean read GetBound;
    property AttachedGeneration: QWord read GetAttachedGeneration;
  public
    constructor Create;
    destructor Destroy; override;
    property DeviceId: string read GetDeviceId;
    property State: TLazBleGattProfileState read GetState;
    property Ready: Boolean read GetReady;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property OnStateChanged: TLazBleGattProfileStateChangedEvent
      read GetOnStateChanged write SetOnStateChanged;
  end;

implementation

function SameProfileStateChangedHandler(const AFirst,
  ASecond: TLazBleGattProfileStateChangedEvent): Boolean;
begin
  Result := (TMethod(AFirst).Code = TMethod(ASecond).Code) and
    (TMethod(AFirst).Data = TMethod(ASecond).Data);
end;

constructor TBleGattProfile.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  InitCriticalSection(FCallbackLock);
  FState := lbgpsDetached;
end;

destructor TBleGattProfile.Destroy;
begin
  SetOnStateChanged(nil);
  EnterCriticalSection(FCallbackLock);
  try
    FStateChangedHandlers := nil;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  FSession := nil;
  DoneCriticalSection(FCallbackLock);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TBleGattProfile.GetCurrentState: TLazBleGattProfileState;
begin
  EnterCriticalSection(FLock);
  try
    Result := FState;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleGattProfile.GetAttachedGeneration: QWord;
begin
  EnterCriticalSection(FLock);
  try
    Result := FAttachedGeneration;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleGattProfile.GetErrorMessage: string;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorMessage;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleGattProfile.GetErrorCode: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FErrorCode;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleGattProfile.GetOnStateChanged:
  TLazBleGattProfileStateChangedEvent;
begin
  EnterCriticalSection(FCallbackLock);
  try
    Result := FOnStateChanged;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleGattProfile.SetOnStateChanged(
  const AHandler: TLazBleGattProfileStateChangedEvent);
begin
  EnterCriticalSection(FCallbackLock);
  try
    FOnStateChanged := AHandler;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

function TBleGattProfile.GetDeviceId: string;
begin
  if Assigned(FSession) then
    Result := FSession.DeviceId
  else
    Result := '';
end;

function TBleGattProfile.GetBound: Boolean;
begin
  Result := Assigned(FSession);
end;

procedure TBleGattProfile.BindSession(const ASession: TBleGattSession);
begin
  if not Assigned(ASession) then
    raise EArgumentNilException.Create('ASession');
  if Assigned(FSession) then
    raise EInvalidOperation.Create('GATT profile is already bound');
  FSession := ASession;
  try
    DoBind;
  except
    FSession := nil;
    raise;
  end;
end;

procedure TBleGattProfile.DoBind;
begin
end;

function TBleGattProfile.GetState: TLazBleGattProfileState;
begin
  if GetCurrentState <> lbgpsDetached then
    RefreshState;
  Result := GetCurrentState;
end;

function TBleGattProfile.GetReady: Boolean;
begin
  Result := GetState = lbgpsReady;
end;

procedure TBleGattProfile.SetState(const AState: TLazBleGattProfileState);
var
  Handler: TLazBleGattProfileStateChangedEvent;
  Handlers: TLazBleGattProfileStateChangedEvents;
begin
  EnterCriticalSection(FLock);
  try
    if FState = AState then
      Exit;
    FState := AState;
  finally
    LeaveCriticalSection(FLock);
  end;
  EnterCriticalSection(FCallbackLock);
  try
    Handler := FOnStateChanged;
    Handlers := Copy(FStateChangedHandlers);
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  if Assigned(Handler) then
    Handler(Self, AState);
  for Handler in Handlers do
    if Assigned(Handler) then
      Handler(Self, AState);
end;

procedure TBleGattProfile.AddStateChangedHandler(
  const AHandler: TLazBleGattProfileStateChangedEvent);
var
  Handler: TLazBleGattProfileStateChangedEvent;
  Index: Integer;
begin
  if not Assigned(AHandler) then
    Exit;
  EnterCriticalSection(FCallbackLock);
  try
    for Handler in FStateChangedHandlers do
      if SameProfileStateChangedHandler(Handler, AHandler) then
        Exit;
    Index := Length(FStateChangedHandlers);
    SetLength(FStateChangedHandlers, Index + 1);
    FStateChangedHandlers[Index] := AHandler;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleGattProfile.RemoveStateChangedHandler(
  const AHandler: TLazBleGattProfileStateChangedEvent);
var
  Index: Integer;
  MoveIndex: Integer;
begin
  EnterCriticalSection(FCallbackLock);
  try
    for Index := 0 to High(FStateChangedHandlers) do
      if SameProfileStateChangedHandler(FStateChangedHandlers[Index],
        AHandler) then
      begin
        for MoveIndex := Index to High(FStateChangedHandlers) - 1 do
          FStateChangedHandlers[MoveIndex] :=
            FStateChangedHandlers[MoveIndex + 1];
        SetLength(FStateChangedHandlers,
          Length(FStateChangedHandlers) - 1);
        Exit;
      end;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleGattProfile.RefreshState;
begin
end;

procedure TBleGattProfile.MarkReady;
begin
  if GetCurrentState = lbgpsAttaching then
    SetState(lbgpsReady);
end;

procedure TBleGattProfile.MarkError(const AMessage: string;
  const AErrorCode: Integer);
begin
  if GetCurrentState = lbgpsDetached then
    Exit;
  EnterCriticalSection(FLock);
  try
    FErrorCode := AErrorCode;
    FErrorMessage := AMessage;
  finally
    LeaveCriticalSection(FLock);
  end;
  SetState(lbgpsError);
end;

procedure TBleGattProfile.Attach;
begin
  if not Assigned(FSession) then
    raise EInvalidOperation.Create('GATT profile is not bound to a client');
  if GetCurrentState <> lbgpsDetached then
    Exit;
  EnterCriticalSection(FLock);
  try
    FErrorCode := 0;
    FErrorMessage := '';
    FAttachedGeneration := FSession.Generation;
  finally
    LeaveCriticalSection(FLock);
  end;
  SetState(lbgpsAttaching);
  DoAttach;
  GetState;
end;

procedure TBleGattProfile.Detach;
begin
  if GetCurrentState = lbgpsDetached then
    Exit;
  DoDetach;
  EnterCriticalSection(FLock);
  try
    FAttachedGeneration := 0;
    FErrorCode := 0;
    FErrorMessage := '';
  finally
    LeaveCriticalSection(FLock);
  end;
  SetState(lbgpsDetached);
end;

end.
