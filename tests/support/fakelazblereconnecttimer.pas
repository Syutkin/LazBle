unit FakeLazBleReconnectTimer;

{$mode objfpc}{$H+}

interface

uses
  LazBleReconnect;

type
  TFakeLazBleReconnectTimer = class(TInterfacedObject,
    ILazBleReconnectTimer)
  private
    FActive: Boolean;
    FDelayMs: Cardinal;
    FStartCount: Integer;
    FCancelCount: Integer;
    FHandler: TLazBleReconnectTimerEvent;
  public
    procedure Start(const ADelayMs: Cardinal;
      const AHandler: TLazBleReconnectTimerEvent);
    procedure Cancel;
    function Trigger: Boolean;
    property Active: Boolean read FActive;
    property DelayMs: Cardinal read FDelayMs;
    property StartCount: Integer read FStartCount;
    property CancelCount: Integer read FCancelCount;
  end;

  TFakeLazBleReconnectTimerFactory = class(TInterfacedObject,
    ILazBleReconnectTimerFactory)
  private
    FLastTimer: TFakeLazBleReconnectTimer;
    FTimerCount: Integer;
  public
    function CreateTimer: ILazBleReconnectTimer;
    property LastTimer: TFakeLazBleReconnectTimer read FLastTimer;
    property TimerCount: Integer read FTimerCount;
  end;

implementation

procedure TFakeLazBleReconnectTimer.Start(const ADelayMs: Cardinal;
  const AHandler: TLazBleReconnectTimerEvent);
begin
  FActive := True;
  FDelayMs := ADelayMs;
  FHandler := AHandler;
  Inc(FStartCount);
end;

procedure TFakeLazBleReconnectTimer.Cancel;
begin
  FActive := False;
  FHandler := nil;
  Inc(FCancelCount);
end;

function TFakeLazBleReconnectTimer.Trigger: Boolean;
var
  Handler: TLazBleReconnectTimerEvent;
begin
  Result := FActive and Assigned(FHandler);
  if not Result then
    Exit;
  FActive := False;
  Handler := FHandler;
  FHandler := nil;
  Handler;
end;

function TFakeLazBleReconnectTimerFactory.CreateTimer:
  ILazBleReconnectTimer;
begin
  FLastTimer := TFakeLazBleReconnectTimer.Create;
  Inc(FTimerCount);
  Result := FLastTimer;
end;

end.
