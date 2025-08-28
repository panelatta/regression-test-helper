package hello;

import com.alibaba.fastjson.JSONObject;
import lombok.extern.slf4j.Slf4j;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.aspectj.lang.annotation.Pointcut;
import org.springframework.stereotype.Component;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import javax.servlet.http.HttpServletRequest;

@Slf4j
@Aspect
@Component
public class WebLogAspect {


    @Pointcut("execution(public * hello.*.*(..))")
    public void webLog() {
    }

    @Around("webLog()")
    public Object doAround(ProceedingJoinPoint proceedingJoinPoint) throws Throwable {
        // 开始打印请求日志
        ServletRequestAttributes attributes = (ServletRequestAttributes) RequestContextHolder.getRequestAttributes();
        HttpServletRequest request = attributes.getRequest();

        // 打印请求相关参数: 请求URL、Http method、请求IP、请求入参
        log.info("【开始处理请求】" +
                        "请求地址URL: {}，" +
                        "请求方法: {}，" +
                        "对应: {}.{}，" +
                        "IP: {}，" +
                        "请求参数: {}",
                request.getRequestURL().toString(),
                request.getMethod(),
                proceedingJoinPoint.getSignature().getDeclaringTypeName(), proceedingJoinPoint.getSignature().getName(),
                request.getRemoteAddr(),
                JSONObject.toJSONString(proceedingJoinPoint.getArgs()));
        long startTime = System.currentTimeMillis();
        Object result = proceedingJoinPoint.proceed();
        // 打印出参、执行耗时
        log.info("返回结果: {}，" +
                        "请求耗时: {} ms",
                JSONObject.toJSONString(result),
                System.currentTimeMillis() - startTime);
        return result;
    }

}