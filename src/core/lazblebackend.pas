unit LazBleBackend;

{$mode objfpc}{$H+}

interface

uses
  LazBleTypes;

type
  ILazBleBackendEventSink = interface
    ['{1F4A66C4-5739-4428-902D-B09F59039602}']
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
  end;

  ILazBleBackend = interface
    ['{80466D51-799E-42D1-95F0-CBD15178B223}']
    { Identity supplied by this backend implementation. The getter must not
      open a native library or start BLE work; return an empty string if the
      name is not yet known. }
    function GetBackendName: string;
    procedure SetEventSink(const AEventSink: ILazBleBackendEventSink);
    function Submit(const ACommand: TLazBleBackendCommand): TBleOperationId;
    procedure Cancel(const AOperationId: TBleOperationId);
    function BeginShutdown: TBleOperationId;
  end;

implementation

end.
