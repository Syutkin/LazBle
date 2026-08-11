unit LazBleLclTranslations;

{$mode objfpc}{$H+}

interface

procedure TranslateLazBleLclResourceStrings(const ALanguageDirectory, ALanguage,
  AFallbackLanguage: string);

implementation

uses
  SysUtils,
  Translations;

procedure TranslateLazBleLclResourceStrings(const ALanguageDirectory, ALanguage,
  AFallbackLanguage: string);
var
  LanguageDirectory: string;
begin
  LanguageDirectory := IncludeTrailingPathDelimiter(ALanguageDirectory);
  TranslateUnitResourceStrings('lazbledeviceselectform', LanguageDirectory +
    'lazbledeviceselectform.%s.po', ALanguage, AFallbackLanguage);
  TranslateUnitResourceStrings('lazbledevicecontrol', LanguageDirectory +
    'lazbledevicecontrol.%s.po', ALanguage, AFallbackLanguage);
end;

end.
