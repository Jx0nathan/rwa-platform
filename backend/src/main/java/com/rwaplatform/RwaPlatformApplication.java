package com.rwaplatform;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@EnableScheduling
public class RwaPlatformApplication {
    public static void main(String[] args) {
        SpringApplication.run(RwaPlatformApplication.class, args);
    }
}
