// ort-cuda-probe — CUDA execution-provider probe for an ONNX Runtime core lib.
//
// Usage: ort-cuda-probe <path-to-libonnxruntime.so*> [--available-only]
//
// Loads the core the way EdgeFirst consumers do (dlopen + OrtGetApiBase, no
// link-time -lonnxruntime) and runs two checks:
//
//   1. The core was compiled with CUDA support: CUDAExecutionProvider is in
//      GetAvailableProviders(). That list is fixed at compile time, so this
//      needs no GPU and no CUDA EP plugin. A CPU-only core fails here; paired
//      with a CUDA EP plugin it rejects the EP with "CUDA execution provider
//      is not enabled in this build".
//   2. (skipped with --available-only) The CUDA EP actually runs: append it to
//      a session with CPU fallback disabled, build a one-node Add model, run
//      it, and compare the result. This dlopens libonnxruntime_providers_cuda.so
//      from the core's directory and initializes CUDA, so it needs a GPU.

#define ORT_API_MANUAL_INIT
#include <onnxruntime_cxx_api.h>

#include <dlfcn.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace {

// Just enough protobuf wire format to build an ONNX ModelProto in memory, so
// the probe needs no model file and no onnx/protobuf tooling.
void put_varint(std::string& out, uint64_t v) {
    while (v >= 0x80) {
        out.push_back(static_cast<char>(v | 0x80));
        v >>= 7;
    }
    out.push_back(static_cast<char>(v));
}

void put_int(std::string& out, int field, uint64_t v) {
    put_varint(out, (static_cast<uint64_t>(field) << 3) | 0);
    put_varint(out, v);
}

void put_bytes(std::string& out, int field, const std::string& bytes) {
    put_varint(out, (static_cast<uint64_t>(field) << 3) | 2);
    put_varint(out, bytes.size());
    out += bytes;
}

// ValueInfoProto for a 1-D float tensor of length n.
std::string float_vector(const std::string& name, int64_t n) {
    std::string dim, shape, tensor, type, info;
    put_int(dim, 1, static_cast<uint64_t>(n));  // Dimension.dim_value
    put_bytes(shape, 1, dim);                   // TensorShapeProto.dim
    put_int(tensor, 1, 1);                      // Tensor.elem_type = FLOAT
    put_bytes(tensor, 2, shape);                // Tensor.shape
    put_bytes(type, 1, tensor);                 // TypeProto.tensor_type
    put_bytes(info, 1, name);                   // ValueInfoProto.name
    put_bytes(info, 2, type);                   // ValueInfoProto.type
    return info;
}

// C = A + B over float[n], opset 13.
std::string add_model(int64_t n) {
    std::string node, graph, opset, model;
    put_bytes(node, 1, "A");      // NodeProto.input
    put_bytes(node, 1, "B");
    put_bytes(node, 2, "C");      // NodeProto.output
    put_bytes(node, 4, "Add");    // NodeProto.op_type
    put_bytes(graph, 1, node);    // GraphProto.node
    put_bytes(graph, 2, "probe"); // GraphProto.name
    put_bytes(graph, 11, float_vector("A", n));
    put_bytes(graph, 11, float_vector("B", n));
    put_bytes(graph, 12, float_vector("C", n));
    put_int(opset, 2, 13);        // OperatorSetIdProto.version (default domain)
    put_int(model, 1, 8);         // ModelProto.ir_version
    put_bytes(model, 7, graph);   // ModelProto.graph
    put_bytes(model, 8, opset);   // ModelProto.opset_import
    return model;
}

int run_cuda_session() {
    constexpr int64_t kN = 4;
    const std::string model = add_model(kN);

    Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "ort-cuda-probe");
    Ort::SessionOptions so;
    // Without this, ORT silently assigns nodes the CUDA EP can't take to the
    // CPU EP and the session "works" without ever touching the GPU.
    so.AddConfigEntry("session.disable_cpu_ep_fallback", "1");
    OrtCUDAProviderOptions cuda{};
    cuda.device_id = 0;
    so.AppendExecutionProvider_CUDA(cuda);
    std::printf("ok: CUDA EP appended (libonnxruntime_providers_cuda.so loaded)\n");

    Ort::Session session(env, model.data(), model.size(), so);
    std::printf("ok: session created with CPU fallback disabled\n");

    std::array<float, kN> a{1.f, 2.f, 3.f, 4.f};
    std::array<float, kN> b{10.f, 20.f, 30.f, 40.f};
    const std::array<int64_t, 1> shape{kN};
    auto mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::array<Ort::Value, 2> inputs{
        Ort::Value::CreateTensor<float>(mem, a.data(), a.size(), shape.data(), shape.size()),
        Ort::Value::CreateTensor<float>(mem, b.data(), b.size(), shape.data(), shape.size()),
    };
    const char* in_names[] = {"A", "B"};
    const char* out_names[] = {"C"};
    auto out = session.Run(Ort::RunOptions{nullptr}, in_names, inputs.data(), inputs.size(), out_names, 1);

    const float* c = out[0].GetTensorData<float>();
    for (int64_t i = 0; i < kN; ++i) {
        if (c[i] != a[i] + b[i]) {
            std::fprintf(stderr, "FAIL: CUDA Add result[%lld] = %g, expected %g\n",
                         static_cast<long long>(i), c[i], a[i] + b[i]);
            return 1;
        }
    }
    std::printf("ok: Add ran on the CUDA EP and returned the expected result\n");
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2 || (argc == 3 && std::strcmp(argv[2], "--available-only") != 0) || argc > 3) {
        std::fprintf(stderr, "usage: %s <path-to-libonnxruntime.so*> [--available-only]\n", argv[0]);
        return 2;
    }
    const bool available_only = argc == 3;

    void* lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (lib == nullptr) {
        std::fprintf(stderr, "FAIL: dlopen: %s\n", dlerror());
        return 1;
    }
    using GetApiBaseFn = const OrtApiBase* (*)();
    auto get_api_base = reinterpret_cast<GetApiBaseFn>(dlsym(lib, "OrtGetApiBase"));
    if (get_api_base == nullptr) {
        std::fprintf(stderr, "FAIL: OrtGetApiBase not exported by %s\n", argv[1]);
        return 1;
    }
    const OrtApiBase* base = get_api_base();
    const OrtApi* api = base->GetApi(ORT_API_VERSION);
    if (api == nullptr) {
        std::fprintf(stderr, "FAIL: core %s does not provide ORT API version %d\n",
                     base->GetVersionString(), ORT_API_VERSION);
        return 1;
    }
    Ort::InitApi(api);
    std::printf("core: %s (ONNX Runtime %s)\n", argv[1], base->GetVersionString());

    try {
        bool cuda_built = false;
        std::printf("available providers:");
        for (const auto& p : Ort::GetAvailableProviders()) {
            std::printf(" %s", p.c_str());
            cuda_built = cuda_built || p == "CUDAExecutionProvider";
        }
        std::printf("\n");
        if (!cuda_built) {
            std::fprintf(stderr,
                         "FAIL: core was built without CUDA support; it will reject the CUDA EP\n"
                         "      plugin with \"CUDA execution provider is not enabled in this build\".\n");
            return 1;
        }
        std::printf("ok: core was built with CUDA support\n");

        if (!available_only && run_cuda_session() != 0) {
            return 1;
        }
    } catch (const Ort::Exception& e) {
        std::fprintf(stderr, "FAIL: %s\n", e.what());
        return 1;
    }

    std::printf("PASS\n");
    return 0;
}
