package com.rwaplatform.config;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * 管理接口 API Key 鉴权过滤器。
 * /api/v1/admin/** 路径需要在 Header 中携带 X-Admin-Key。
 */
@Slf4j
@Configuration
public class SecurityConfig {

    @Value("${rwa.admin-api-key}")
    private String adminApiKey;

    @Bean
    public OncePerRequestFilter adminAuthFilter() {
        return new OncePerRequestFilter() {
            @Override
            protected void doFilterInternal(HttpServletRequest request,
                                            HttpServletResponse response,
                                            FilterChain filterChain)
                    throws ServletException, IOException {

                String path = request.getRequestURI();
                if (path.startsWith("/api/v1/admin")) {
                    String key = request.getHeader("X-Admin-Key");
                    if (key == null || !key.equals(adminApiKey)) {
                        log.warn("[Security] 未授权的管理接口访问: {}", path);
                        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
                        response.setContentType("application/json");
                        response.getWriter().write("{\"error\":\"Unauthorized\"}");
                        return;
                    }
                }
                filterChain.doFilter(request, response);
            }
        };
    }
}
