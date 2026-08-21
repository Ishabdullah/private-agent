import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/ai_service.dart';

void main() {
  test('recognizes only the NVIDIA hosted API URL', () {
    expect(
      AiService.isNvidiaBaseUrl('https://integrate.api.nvidia.com/v1'),
      isTrue,
    );
    expect(AiService.isNvidiaBaseUrl('https://api.deepseek.com'), isFalse);
  });

  test('isLikelyLocalServer recognizes loopback and LAN hosts', () {
    expect(AiService.isLikelyLocalServer('http://127.0.0.1:8080/v1'), isTrue);
    expect(AiService.isLikelyLocalServer('http://10.0.2.2:1234/v1'), isTrue);
    expect(
      AiService.isLikelyLocalServer('http://192.168.1.111:8080/v1'),
      isTrue,
    );
    expect(AiService.isLikelyLocalServer('http://10.1.2.3:8080/v1'), isTrue);
    expect(AiService.isLikelyLocalServer('http://172.16.0.5:8080/v1'), isTrue);
    expect(
      AiService.isLikelyLocalServer('http://localhost:8080/v1'),
      isTrue,
    );
  });

  test('isLikelyLocalServer rejects public/cloud hosts', () {
    expect(AiService.isLikelyLocalServer('https://api.deepseek.com'), isFalse);
    expect(
      AiService.isLikelyLocalServer('https://integrate.api.nvidia.com/v1'),
      isFalse,
    );
    expect(
      AiService.isLikelyLocalServer('http://172.32.0.5:8080/v1'),
      isFalse,
    );
  });

  test('NVIDIA model picker keeps only verified free chat models', () {
    final models = AiService.filterNvidiaFreeModels([
      'paid/partner-model',
      'nvidia/nemotron-3-super-120b-a12b',
      'nvidia/embed-qa-4',
      'openai/gpt-oss-20b',
    ]);

    expect(models, ['nvidia/nemotron-3-super-120b-a12b', 'openai/gpt-oss-20b']);
  });

  test('GLM is the default NVIDIA model', () {
    expect(AiService.nvidiaDefaultModel, 'z-ai/glm-5.2');
    expect(AiService.nvidiaFreeChatModels.first, 'z-ai/glm-5.2');
  });
}
