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

  { Base class for a client-owned GATT profile. Add it to TBleClient before
    connecting; the client binds, attaches, detaches and frees the profile. }
  TBleGattProfile = class abstract
  private
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
    { Override to allocate session-bound helpers. }
    procedure DoBind; virtual;
    { Override to begin service discovery dependent work and call MarkReady or
      MarkError when attachment reaches a terminal result. }
    procedure DoAttach; virtual; abstract;
    { Override to release active subscriptions and pending profile work. }
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
    { True only while attachment has reached lbgpsReady. }
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
  FState := lbgpsDetached;
end;

destructor TBleGattProfile.Destroy;
begin
  SetOnStateChanged(nil);
  FStateChangedHandlers := nil;
  FSession := nil;
  inherited Destroy;
end;

function TBleGattProfile.GetCurrentState: TLazBleGattProfileState;
begin
  LazBleRequireMainThread;
  Result := FState;
end;

function TBleGattProfile.GetAttachedGeneration: QWord;
begin
  LazBleRequireMainThread;
  Result := FAttachedGeneration;
end;

function TBleGattProfile.GetErrorMessage: string;
begin
  LazBleRequireMainThread;
  Result := FErrorMessage;
end;

function TBleGattProfile.GetErrorCode: Integer;
begin
  LazBleRequireMainThread;
  Result := FErrorCode;
end;

function TBleGattProfile.GetOnStateChanged:
  TLazBleGattProfileStateChangedEvent;
begin
  LazBleRequireMainThread;
  Result := FOnStateChanged;
end;

procedure TBleGattProfile.SetOnStateChanged(
  const AHandler: TLazBleGattProfileStateChangedEvent);
begin
  LazBleRequireMainThread;
  FOnStateChanged := AHandler;
end;

function TBleGattProfile.GetDeviceId: string;
begin
  LazBleRequireMainThread;
  if Assigned(FSession) then
    Result := FSession.DeviceId
  else
    Result := '';
end;

function TBleGattProfile.GetBound: Boolean;
begin
  LazBleRequireMainThread;
  Result := Assigned(FSession);
end;

procedure TBleGattProfile.BindSession(const ASession: TBleGattSession);
begin
  LazBleRequireMainThread;
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
  LazBleRequireMainThread;
end;

function TBleGattProfile.GetState: TLazBleGattProfileState;
begin
  LazBleRequireMainThread;
  if GetCurrentState <> lbgpsDetached then
    RefreshState;
  Result := GetCurrentState;
end;

function TBleGattProfile.GetReady: Boolean;
begin
  LazBleRequireMainThread;
  Result := GetState = lbgpsReady;
end;

procedure TBleGattProfile.SetState(const AState: TLazBleGattProfileState);
var
  Handler: TLazBleGattProfileStateChangedEvent;
  Handlers: TLazBleGattProfileStateChangedEvents;
begin
  LazBleRequireMainThread;
  if FState = AState then
    Exit;
  FState := AState;
  Handler := FOnStateChanged;
  Handlers := Copy(FStateChangedHandlers);
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
  LazBleRequireMainThread;
  if not Assigned(AHandler) then
    Exit;
  for Handler in FStateChangedHandlers do
    if SameProfileStateChangedHandler(Handler, AHandler) then
      Exit;
  Index := Length(FStateChangedHandlers);
  SetLength(FStateChangedHandlers, Index + 1);
  FStateChangedHandlers[Index] := AHandler;
end;

procedure TBleGattProfile.RemoveStateChangedHandler(
  const AHandler: TLazBleGattProfileStateChangedEvent);
var
  Index: Integer;
  MoveIndex: Integer;
begin
  LazBleRequireMainThread;
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
end;

procedure TBleGattProfile.RefreshState;
begin
  LazBleRequireMainThread;
end;

procedure TBleGattProfile.MarkReady;
begin
  LazBleRequireMainThread;
  if GetCurrentState = lbgpsAttaching then
    SetState(lbgpsReady);
end;

procedure TBleGattProfile.MarkError(const AMessage: string;
  const AErrorCode: Integer);
begin
  LazBleRequireMainThread;
  if GetCurrentState = lbgpsDetached then
    Exit;
  FErrorCode := AErrorCode;
  FErrorMessage := AMessage;
  SetState(lbgpsError);
end;

procedure TBleGattProfile.Attach;
begin
  LazBleRequireMainThread;
  if not Assigned(FSession) then
    raise EInvalidOperation.Create('GATT profile is not bound to a client');
  if GetCurrentState <> lbgpsDetached then
    Exit;
  FErrorCode := 0;
  FErrorMessage := '';
  FAttachedGeneration := FSession.Generation;
  SetState(lbgpsAttaching);
  DoAttach;
  GetState;
end;

procedure TBleGattProfile.Detach;
begin
  LazBleRequireMainThread;
  if GetCurrentState = lbgpsDetached then
    Exit;
  DoDetach;
  FAttachedGeneration := 0;
  FErrorCode := 0;
  FErrorMessage := '';
  SetState(lbgpsDetached);
end;

end.
