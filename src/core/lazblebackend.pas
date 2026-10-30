unit LazBleBackend;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, LazBleTypes;

type
  TLazBleRequestStatus = (lbrsSucceeded, lbrsFailed, lbrsCancelled);

  { One immutable terminal snapshot. Status, not error code/text, determines
    the outcome. Payloads are read-only managed data. }
  TLazBleRequestResult = record
    Status: TLazBleRequestStatus;
    ErrorCode: Integer;
    ErrorMessage: string;
    Value: TBytes;
    Services: TLazBleGattServices;
    ScanResults: TBleDeviceInfos;
    SubscriptionId: TBleSubscriptionId;
    Availability: TBleAvailability;
    BackendName, BackendVersion, AdapterId: string;
  end;

  ILazBleRequestCompletion = interface
    ['{037F83CB-AF54-4EF2-8578-C20AA20E1A53}']
    procedure CompleteRequest(const AResult: TLazBleRequestResult);
  end;

  ILazBleValueSink = interface
    ['{6B4C326A-B1B5-4D10-8E39-69646003D32B}']
    procedure ReceiveValue(const AValue: TBytes);
  end;

  ILazBleScanSink = interface
    ['{C256C4DA-BABB-45E4-96F3-66B134D5A765}']
    procedure ReceiveScanResult(const ADevice: TBleDeviceInfo);
  end;

  ILazBleLinkObserver = interface
    ['{4A1CBA76-207E-4B90-818F-4D33DF80027C}']
    procedure LinkChanged(const AConnected: Boolean; const AGeneration: QWord);
  end;

  { Main-thread API and callbacks. Accepted requests complete once, after Submit
    returns, with status and payload together. Cancel is best effort: started
    native calls retain their actual outcome. Shutdown drains requests and
    cleanup before its completion. Write buffers are copied at Submit.
    Pump CheckSynchronize/the LCL loop, and defer destruction from callbacks. }
  ILazBleBackend = interface
    ['{80466D51-799E-42D1-95F0-CBD15178B223}']
    { Identity supplied by this backend implementation. The getter must not
      start BLE work; return an empty string if the
      name is not yet known. }
    function GetBackendName: string;
    { Return InvalidBleOperationId when a command cannot be started. }
    function Submit(const ACommand: TLazBleBackendCommand;
      const ACompletion: ILazBleRequestCompletion;
      const AValues: ILazBleValueSink = nil;
      const AScan: ILazBleScanSink = nil;
      const ALink: ILazBleLinkObserver = nil): TBleOperationId;
    procedure Cancel(const AOperationId: TBleOperationId);
    { Begin orderly backend shutdown and return its operation ID. }
    function BeginShutdown(const ACompletion: ILazBleRequestCompletion = nil): TBleOperationId;
  end;

{ Call only from an exception handler at an asynchronous callback boundary. }
procedure LazBleReportCallbackException;

implementation

procedure LazBleReportCallbackException;
begin
  try
    if Assigned(ApplicationHandleException) then ApplicationHandleException(nil)
    else ShowException(ExceptObject, ExceptAddr);
  except
    { A failing exception reporter must not interrupt request completion. }
  end;
end;

end.
