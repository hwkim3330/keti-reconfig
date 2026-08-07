import 'package:webview_flutter/webview_flutter.dart';
import '../core/constants.dart';

class ViewerService {
  WebViewController? _controller;

  void setController(WebViewController controller) {
    _controller = controller;
  }

  // JavaScript 준비 완료 체크
  Future<bool> isJsReady() async {
    final result = await _controller?.runJavaScriptReturningResult(
      'window.jsReady || false',
    );
    return result == true || result.toString() == 'true';
  }

  // Label Hotspot 초기화
  Future<void> initializeLabelHotspots() async {
    final json = labelHotspotsToJson();
    await _controller?.runJavaScript(
      'window.createLabelHotspots && window.createLabelHotspots(\'$json\');',
    );
  }

  Future<void> toggleMaterials() async {
    await _controller?.runJavaScript('window.toggleMaterials?.()');
  }

  Future<void> setVehicleShellOpacity(double opacity) async {
    final value = opacity.clamp(0.0, 1.0).toStringAsFixed(3);
    await _controller?.runJavaScript('window.setVehicleShellOpacity?.($value)');
  }

  Future<void> switchOrbit() async {
    await _controller?.runJavaScript('window.switchOrbit?.()');
  }

  /// Absolute camera orbit in degrees, used by the tilt control.
  Future<void> setCameraOrbit(double theta, double phi) async {
    await _controller?.runJavaScript(
      'window.setOrbit?.(${theta.toStringAsFixed(1)}, ${phi.toStringAsFixed(1)})',
    );
  }

  Future<void> resetCameraOrbit() async {
    await _controller?.runJavaScript('window.resetCamera?.()');
  }

  Future<void> toggleHotspots(bool visible) async {
    await _controller?.runJavaScript('window.toggleHotspots?.($visible)');
  }

  // Error Hotspot 생성 + Material 점멸 시작
  Future<void> showFaultAlert(
    String materialName,
    int severity,
    ErrorHotspotConfig config,
  ) async {
    // Error hotspot 생성
    await _controller?.runJavaScript('''
      window.createErrorHotspot?.(
        "$materialName",
        $severity,
        "${config.position}",
        "${config.dataTarget}",
        "${config.dataOrbit}"
      )
    ''');
    // Material 점멸 추가 (여러 개 동시 점멸 가능)
    for (final material
        in alertMaterialGroups[materialName] ?? [materialName]) {
      await _controller?.runJavaScript('window.addAlertTarget?.("$material")');
    }
  }

  // Fault alert 숨기기 (hotspot 제거 + 해당 material 점멸 중지)
  Future<void> hideFaultAlert(String materialName) async {
    await _controller?.runJavaScript(
      'window.removeErrorHotspot?.("$materialName")',
    );
    for (final material
        in alertMaterialGroups[materialName] ?? [materialName]) {
      await _controller?.runJavaScript(
        'window.removeAlertTarget?.("$material")',
      );
    }
  }

  Future<void> stopAlert() async {
    await _controller?.runJavaScript('window.stopAlert?.()');
  }

  Future<void> clearFaultAlerts() async {
    await _controller?.runJavaScript('window.clearFaultAlerts?.()');
  }

  Future<String?> checkErrorHotspotClicked() async {
    final result = await _controller?.runJavaScriptReturningResult(
      'window.errorHotspotClicked || null',
    );
    if (result != null && result.toString() != 'null') {
      await _controller?.runJavaScript('window.errorHotspotClicked = null');
      return result.toString().replaceAll('"', '');
    }
    return null;
  }
}
