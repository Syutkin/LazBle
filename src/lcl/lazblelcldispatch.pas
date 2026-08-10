unit LazBleLclDispatch;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils;

type
  TLazBleLclDispatchMessage = class
  public
    function Clone: TLazBleLclDispatchMessage; virtual; abstract;
  end;

  TLazBleLclDispatchMessageEvent = procedure(Sender: TObject;
    const AMessage: TLazBleLclDispatchMessage) of object;

  TLazBleLclDispatch = class
  private
    FLock: TRTLCriticalSection;
    FTarget: IInterface;
    function GetTarget: IInterface;
  public
    constructor Create(const AHandler: TLazBleLclDispatchMessageEvent);
    destructor Destroy; override;
    function CaptureGeneration: QWord;
    function NextGeneration: QWord;
    procedure Queue(const AMessage: TLazBleLclDispatchMessage);
    procedure Detach;
  end;

implementation

type
  ILazBleLclDispatchTarget = interface
    ['{948E6262-A59E-4493-B53B-48528F7793E0}']
    function CaptureGeneration: QWord;
    function NextGeneration: QWord;
    procedure Queue(const AMessage: TLazBleLclDispatchMessage);
    procedure Detach;
    procedure Deliver(const AGeneration: QWord;
      const AMessage: TLazBleLclDispatchMessage);
  end;

  TLazBleLclDispatchTarget = class(TInterfacedObject,
    ILazBleLclDispatchTarget)
  private
    FLock: TRTLCriticalSection;
    FGeneration: QWord;
    FDetached: Boolean;
    FHandler: TLazBleLclDispatchMessageEvent;
  public
    constructor Create(const AHandler: TLazBleLclDispatchMessageEvent);
    destructor Destroy; override;
    function CaptureGeneration: QWord;
    function NextGeneration: QWord;
    procedure Queue(const AMessage: TLazBleLclDispatchMessage);
    procedure Detach;
    procedure Deliver(const AGeneration: QWord;
      const AMessage: TLazBleLclDispatchMessage);
  end;

  TLazBleLclQueuedDelivery = class
  private
    FTarget: ILazBleLclDispatchTarget;
    FGeneration: QWord;
    FMessage: TLazBleLclDispatchMessage;
  public
    constructor Create(const ATarget: ILazBleLclDispatchTarget;
      const AGeneration: QWord; const AMessage: TLazBleLclDispatchMessage);
    procedure Deliver;
  end;

constructor TLazBleLclDispatchTarget.Create(
  const AHandler: TLazBleLclDispatchMessageEvent);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FGeneration := 1;
  FHandler := AHandler;
end;

destructor TLazBleLclDispatchTarget.Destroy;
begin
  Detach;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TLazBleLclDispatchTarget.CaptureGeneration: QWord;
begin
  EnterCriticalSection(FLock);
  try
    Result := FGeneration;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLazBleLclDispatchTarget.NextGeneration: QWord;
begin
  EnterCriticalSection(FLock);
  try
    if not FDetached then
      Inc(FGeneration);
    Result := FGeneration;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLazBleLclDispatchTarget.Queue(
  const AMessage: TLazBleLclDispatchMessage);
var
  Delivery: TLazBleLclQueuedDelivery;
  Generation: QWord;
  MessageCopy: TLazBleLclDispatchMessage;
begin
  EnterCriticalSection(FLock);
  try
    if FDetached then
      Exit;
    Generation := FGeneration;
  finally
    LeaveCriticalSection(FLock);
  end;

  MessageCopy := AMessage.Clone;
  try
    Delivery := TLazBleLclQueuedDelivery.Create(Self, Generation, MessageCopy);
    MessageCopy := nil;
    TThread.Queue(nil, @Delivery.Deliver);
  finally
    MessageCopy.Free;
  end;
end;

procedure TLazBleLclDispatchTarget.Detach;
begin
  EnterCriticalSection(FLock);
  try
    if FDetached then
      Exit;
    FDetached := True;
    Inc(FGeneration);
    FHandler := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLazBleLclDispatchTarget.Deliver(const AGeneration: QWord;
  const AMessage: TLazBleLclDispatchMessage);
var
  Handler: TLazBleLclDispatchMessageEvent;
begin
  Handler := nil;
  EnterCriticalSection(FLock);
  try
    if (not FDetached) and (AGeneration = FGeneration) then
      Handler := FHandler;
  finally
    LeaveCriticalSection(FLock);
  end;

  if Assigned(Handler) then
    Handler(Self, AMessage);
end;

constructor TLazBleLclQueuedDelivery.Create(
  const ATarget: ILazBleLclDispatchTarget; const AGeneration: QWord;
  const AMessage: TLazBleLclDispatchMessage);
begin
  inherited Create;
  FTarget := ATarget;
  FGeneration := AGeneration;
  FMessage := AMessage;
end;

procedure TLazBleLclQueuedDelivery.Deliver;
begin
  try
    FTarget.Deliver(FGeneration, FMessage);
  finally
    FMessage.Free;
    FMessage := nil;
    FTarget := nil;
    Free;
  end;
end;

constructor TLazBleLclDispatch.Create(
  const AHandler: TLazBleLclDispatchMessageEvent);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FTarget := TLazBleLclDispatchTarget.Create(AHandler);
end;

destructor TLazBleLclDispatch.Destroy;
begin
  Detach;
  EnterCriticalSection(FLock);
  try
    FTarget := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TLazBleLclDispatch.GetTarget: IInterface;
begin
  EnterCriticalSection(FLock);
  try
    Result := FTarget;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLazBleLclDispatch.CaptureGeneration: QWord;
var
  Target: ILazBleLclDispatchTarget;
begin
  Target := GetTarget as ILazBleLclDispatchTarget;
  if Assigned(Target) then
    Result := Target.CaptureGeneration
  else
    Result := 0;
end;

function TLazBleLclDispatch.NextGeneration: QWord;
var
  Target: ILazBleLclDispatchTarget;
begin
  Target := GetTarget as ILazBleLclDispatchTarget;
  if Assigned(Target) then
    Result := Target.NextGeneration
  else
    Result := 0;
end;

procedure TLazBleLclDispatch.Queue(
  const AMessage: TLazBleLclDispatchMessage);
var
  Target: ILazBleLclDispatchTarget;
begin
  if not Assigned(AMessage) then
    raise EArgumentNilException.Create('AMessage');
  Target := GetTarget as ILazBleLclDispatchTarget;
  if Assigned(Target) then
    Target.Queue(AMessage);
end;

procedure TLazBleLclDispatch.Detach;
var
  Target: ILazBleLclDispatchTarget;
begin
  Target := GetTarget as ILazBleLclDispatchTarget;
  if Assigned(Target) then
    Target.Detach;
end;

end.
