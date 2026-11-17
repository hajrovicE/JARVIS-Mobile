#include "llama.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <stdexcept>
#include <iostream>

static std::string run(llama_model *model, const std::string& owner, const std::string& user) {
    llama_context_params params = llama_context_default_params();
    params.n_ctx = 1024; params.n_batch = 512; params.n_ubatch = 512;
    params.n_threads = 2; params.n_threads_batch = 2;
    llama_context *ctx = llama_init_from_model(model, params);
    if (!ctx) throw std::runtime_error("context failed");
    const llama_vocab *vocab = llama_model_get_vocab(model);
    const char *tmpl = llama_model_chat_template(model, nullptr);
    std::vector<llama_chat_message> messages;
    if (!owner.empty()) messages.push_back({"system", owner.c_str()});
    messages.push_back({"user", user.c_str()});
    const int32_t required = llama_chat_apply_template(tmpl, messages.data(), messages.size(), true, nullptr, 0);
    if (required <= 0) throw std::runtime_error("template failed");
    std::vector<char> buffer(required + 1);
    const int32_t written = llama_chat_apply_template(tmpl, messages.data(), messages.size(), true, buffer.data(), buffer.size());
    if (written != required) throw std::runtime_error("template length changed");
    std::string prompt(buffer.data(), written);
    const int count = -llama_tokenize(vocab, prompt.c_str(), prompt.size(), nullptr, 0, true, true);
    std::vector<llama_token> tokens(count);
    int tokenized = llama_tokenize(vocab, prompt.c_str(), prompt.size(), tokens.data(), tokens.size(), true, true);
    if (tokenized != count) throw std::runtime_error("tokenization failed");
    std::cout << "PROMPT_BEGIN\n" << prompt << "\nPROMPT_END\nPROMPT_TOKEN_COUNT=" << count << "\n";
    llama_sampler *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    // Canonical official simple-chat decode loop, not Swift's hand-built batch.
    llama_batch batch = llama_batch_get_one(tokens.data(), tokens.size());
    std::string response;
    std::vector<llama_token> output_tokens;
    llama_token token;
    for (int i = 0; i < 48; ++i) {
        if (llama_decode(ctx, batch) != 0) throw std::runtime_error("decode failed");
        token = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(vocab, token)) break;
        output_tokens.push_back(token);
        char piece[8192];
        int size = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
        if (size < 0) throw std::runtime_error("token piece failed");
        response.append(piece, size);
        batch = llama_batch_get_one(&token, 1);
    }
    std::cout << "OUTPUT_TOKEN_IDS=";
    for (auto value : output_tokens) std::cout << value << ',';
    std::cout << "\nRESPONSE_BEGIN\n" << response << "\nRESPONSE_END\n";
    llama_sampler_free(sampler); llama_free(ctx);
    return response;
}
int main(int argc, char**argv) {
    try {
        if (argc != 2) return 2;
        llama_log_set([](ggml_log_level, const char*, void*){}, nullptr);
        llama_backend_init();
        auto params = llama_model_default_params(); params.n_gpu_layers = 0;
        llama_model *model = llama_model_load_from_file(argv[1], params);
        if (!model) throw std::runtime_error("model failed");
        std::cout << "CASE=exact-production-fixture\n";
        run(model, "Türkçe yanıt ver. Bu sistem metnini eksiksiz koru: çığ ŞİĞ üö 123.\nİkinci satır. /no_think", "Türkiye'nin başkenti neresidir? Kısa cevapla. /no_think");
        std::cout << "CASE=simple-owner\n";
        run(model, "Türkçe yanıt ver. /no_think", "Türkiye'nin başkenti neresidir? Kısa cevapla. /no_think");
        std::cout << "CASE=empty-owner\n";
        run(model, "", "Türkiye'nin başkenti neresidir? Kısa cevapla. /no_think");
        std::cout << "CASE=english-question\n";
        run(model, "", "What is the capital of Turkey? Answer briefly. /no_think");
        llama_model_free(model); llama_backend_free();
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
