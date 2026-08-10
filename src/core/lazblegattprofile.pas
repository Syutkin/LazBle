unit LazBleGattProfile;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
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
    FSession: TBleGattSession;
    FState: TLazBleGattProfileState;
    FErrorMessage: string;
    FAttachedGeneration: QWord;
    FOnStateChanged: TLazBleGattProfileStateChangedEvent;
    FStateChangedHandlers: TLazBleGattProfileStateChangedEvents;
    function GetDeviceId: string;
    function GetState: TLazBleGattProfileState;
    function GetReady: Boolean;
    procedure SetState(const AState: TLazBleGattProfileState);
  protected
    procedure DoAttach; virtual; abstract;
    procedure DoDetach; virtual; abstract;
    procedure RefreshState; virtual;
    procedure MarkReady;
    procedure MarkError(const AMessage: string);
    property CurrentState: TLazBleGattProfileState read FState;
  public
    constructor Create(const ASession: TBleGattSession);
    destructor Destroy; override;
    procedure Attach;
    procedure Detach;
    procedure AddStateChangedHandler(
      const AHandler: TLazBleGattProfileStateChangedEvent);
    procedure RemoveStateChangedHandler(
      const AHandler: TLazBleGattProfileStateChangedEvent);
    property Session: TBleGattSession read FSession;
    property DeviceId: string read GetDeviceId;
    property AttachedGeneration: QWord read FAttachedGeneration;
    property State: TLazBleGattProfileState read GetState;
    property Ready: Boolean read GetReady;
    property ErrorMessage: string read FErrorMessage;
    property OnStateChanged: TLazBleGattProfileStateChangedEvent
      read FOnStateChanged write FOnStateChanged;
  end;

implementation

function SameProfileStateChangedHandler(const AFirst,
  ASecond: TLazBleGattProfileStateChangedEvent): Boolean;
begin
  Result := (TMethod(AFirst).Code = TMethod(ASecond).Code) and
    (TMethod(AFirst).Data = TMethod(ASecond).Data);
end;

constructor TBleGattProfile.Create(const ASession: TBleGattSession);
begin
  inherited Create;
  if not Assigned(ASession) then
    raise EArgumentNilException.Create('ASession');
  FSession := ASession;
  FState := lbgpsDetached;
end;

destructor TBleGattProfile.Destroy;
begin
  FOnStateChanged := nil;
  FSession := nil;
  inherited Destroy;
end;

function TBleGattProfile.GetDeviceId: string;
begin
  if Assigned(FSession) then
    Result := FSession.DeviceId
  else
    Result := '';
end;

function TBleGattProfile.GetState: TLazBleGattProfileState;
begin
  if FState <> lbgpsDetached then
    RefreshState;
  Result := FState;
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
  if FState = AState then
    Exit;
  FState := AState;
  if Assigned(FOnStateChanged) then
    FOnStateChanged(Self, FState);
  Handlers := Copy(FStateChangedHandlers);
  for Handler in Handlers do
    if Assigned(Handler) then
      Handler(Self, FState);
end;

procedure TBleGattProfile.AddStateChangedHandler(
  const AHandler: TLazBleGattProfileStateChangedEvent);
var
  Handler: TLazBleGattProfileStateChangedEvent;
  Index: Integer;
begin
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
  for Index := 0 to High(FStateChangedHandlers) do
    if SameProfileStateChangedHandler(FStateChangedHandlers[Index],
      AHandler) then
    begin
      for MoveIndex := Index to High(FStateChangedHandlers) - 1 do
        FStateChangedHandlers[MoveIndex] :=
          FStateChangedHandlers[MoveIndex + 1];
      SetLength(FStateChangedHandlers, Length(FStateChangedHandlers) - 1);
      Exit;
    end;
end;

procedure TBleGattProfile.RefreshState;
begin
end;

procedure TBleGattProfile.MarkReady;
begin
  if FState = lbgpsAttaching then
    SetState(lbgpsReady);
end;

procedure TBleGattProfile.MarkError(const AMessage: string);
begin
  if FState = lbgpsDetached then
    Exit;
  FErrorMessage := AMessage;
  SetState(lbgpsError);
end;

procedure TBleGattProfile.Attach;
begin
  if FState <> lbgpsDetached then
    Exit;
  FErrorMessage := '';
  FAttachedGeneration := FSession.Generation;
  SetState(lbgpsAttaching);
  DoAttach;
  GetState;
end;

procedure TBleGattProfile.Detach;
begin
  if FState = lbgpsDetached then
    Exit;
  DoDetach;
  FAttachedGeneration := 0;
  FErrorMessage := '';
  SetState(lbgpsDetached);
end;

end.
