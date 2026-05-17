!include LogicLib.nsh

!ifdef APP_ARM64
  !define VC_REDIST_ARCH "arm64"
  !define VC_REDIST_REGKEY "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\ARM64"
!else
  !define VC_REDIST_ARCH "x64"
  !define VC_REDIST_REGKEY "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
!endif

!ifndef BUILD_UNINSTALLER
  Function checkVCRedist
    ReadRegDWORD $0 HKLM "${VC_REDIST_REGKEY}" "Installed"
  FunctionEnd
!endif

!macro customInit
  Delete "$INSTDIR\Uninstall*.exe"

  Push $0
  Call checkVCRedist
  ${If} $0 != "1"
    inetc::get /CAPTION " " /BANNER "Downloading Microsoft Visual C++ Redistributable..." "https://aka.ms/vs/17/release/vc_redist.${VC_REDIST_ARCH}.exe" "$TEMP\vc_redist.${VC_REDIST_ARCH}.exe"
    ExecWait "$TEMP\vc_redist.${VC_REDIST_ARCH}.exe /install /norestart /passive"
    ;IfErrors InstallError ContinueInstall ; vc_redist exit code is unreliable :(
    Call checkVCRedist
    ${If} $0 == "1"
      Goto ContinueInstall
    ${EndIf}

    ;InstallError:
      MessageBox MB_ICONSTOP "\
        There was an unexpected error installing$\r$\n\
        Microsoft Visual C++ Redistributable.$\r$\n\
        The installation of ${PRODUCT_NAME} cannot continue."
  ${EndIf}
  ContinueInstall:
    Pop $0
!macroend
